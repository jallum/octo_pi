defmodule OctoPi.AI.Providers.OpenAI.Producer do
  @moduledoc """
  Per-call OpenAI streaming worker.

  Runs as a supervised Task under `OctoPi.AI.Providers.OpenAI.TaskSup`.
  Same lifecycle as the Anthropic producer: emit start, drain HTTP body
  via `Req.post!(into: :self)`, SSE decode, JSON parse, feed decoder,
  send events to caller, emit terminal, send `:done` sentinel, exit.

  OpenAI differs from Anthropic in SSE format: no `event:` field, just
  `data:` lines, and `data: [DONE]` as the terminal sentinel (skip it,
  it's not valid JSON).

  Ported from `openai-completions.ts` L110-196.
  """

  alias OctoPi.AI.{CallOptions, PartialJson, SSE, Telemetry}
  alias OctoPi.AI.Providers.OpenAI.{Auth, Compat, Decoder, Request}
  alias OctoPi.AI.SSE.Event, as: SseEvent

  @type start_arg :: %{
          required(:model) => OctoPi.AI.Model.t(),
          required(:context) => OctoPi.AI.Context.t(),
          required(:opts) => OctoPi.AI.CallOptions.t(),
          required(:caller) => pid(),
          optional(:req_overrides) => keyword()
        }

  @spec start(start_arg()) :: {:ok, pid()} | {:error, term()}
  def start(%{} = args) do
    Task.Supervisor.start_child(
      OctoPi.AI.Providers.OpenAI.TaskSup,
      fn -> run(args) end,
      restart: :temporary
    )
  end

  @spec run(start_arg()) :: :ok
  def run(%{} = args) do
    caller_mon = Process.monitor(args.caller)
    start_mono = System.monotonic_time()
    Telemetry.request_start(args.model)

    compat = Compat.resolve(args.model)
    {start_event, decoder_state} = Decoder.new(args.model)

    send(args.caller, {self(), :event, start_event})

    state = %{
      caller: args.caller,
      caller_mon: caller_mon,
      model: args.model,
      sse: SSE.new(),
      decoder: decoder_state,
      aborted?: false
    }

    opts = ensure_api_key(args.opts, args.model)
    req_spec = Request.build(args.model, args.context, opts, compat)

    body = apply_on_payload(req_spec.body, opts, args.model)

    req_opts =
      [
        url: req_spec.url,
        headers: req_spec.headers,
        json: body,
        receive_timeout: :infinity,
        into: :self
      ] ++ Map.get(args, :req_overrides, [])

    state =
      try do
        resp = Req.post!(req_opts)
        apply_on_response(resp, opts, args.model)
        state = drain_body(resp, state)
        state = flush_sse(state)

        state =
          cond do
            state.aborted? ->
              emit_error(state, "aborted by caller", :aborted)

            resp.status in 200..299 ->
              emit_done_or_error(state)

            true ->
              emit_http_error(state, resp)
          end

        emit_request_stop(state, start_mono, http_status: resp.status)
        state
      rescue
        e in [Req.TransportError, Jason.DecodeError, RuntimeError, ArgumentError] ->
          state = emit_error(state, Exception.message(e), :error)
          emit_request_exception(state, start_mono, :error, Exception.message(e))
          state
      end

    send(state.caller, {self(), :done})
    :ok
  end

  # --- body drain ---

  defp drain_body(resp, state) do
    receive do
      {:DOWN, mon, :process, _, _} when mon == state.caller_mon ->
        %{state | aborted?: true}

      message ->
        case Req.parse_message(resp, message) do
          {:ok, parts} ->
            state = process_parts(parts, state)
            if Enum.member?(parts, :done), do: state, else: drain_body(resp, state)

          :unknown ->
            drain_body(resp, state)

          {:error, reason} ->
            raise "Req stream error: #{inspect(reason)}"
        end
    end
  end

  defp process_parts(parts, state) do
    Enum.reduce(parts, state, fn
      {:data, chunk}, st -> process_chunk(chunk, st)
      :done, st -> st
      _other, st -> st
    end)
  end

  defp process_chunk(chunk, state) do
    {sse_events, sse} = SSE.decode(state.sse, chunk)
    decoder = apply_sse_events(sse_events, state.decoder, state.caller)
    %{state | sse: sse, decoder: decoder}
  end

  defp flush_sse(state) do
    {sse_events, sse} = SSE.finalize(state.sse)
    decoder = apply_sse_events(sse_events, state.decoder, state.caller)
    %{state | sse: sse, decoder: decoder}
  end

  defp apply_sse_events(sse_events, decoder, caller) do
    Enum.reduce(sse_events, decoder, fn sse_ev, dstate ->
      handle_sse_event(sse_ev, dstate, caller)
    end)
  end

  defp handle_sse_event(%SseEvent{data: "[DONE]"}, dstate, _caller), do: dstate

  defp handle_sse_event(%SseEvent{data: data}, dstate, caller) do
    case PartialJson.parse_with_repair(data) do
      {:ok, event} when is_map(event) ->
        {events, dstate} = Decoder.handle(dstate, event)
        Enum.each(events, &send(caller, {self(), :event, &1}))
        dstate

      _ ->
        dstate
    end
  end

  # --- auth ---

  defp ensure_api_key(%CallOptions{api_key: key} = opts, _model)
       when is_binary(key) and key != "",
       do: opts

  defp ensure_api_key(%CallOptions{} = opts, model),
    do: %{opts | api_key: Auth.resolve(model, opts)}

  # --- callbacks ---

  defp apply_on_payload(body, %{on_payload: fun}, model) when is_function(fun, 2) do
    case fun.(body, model) do
      result when is_map(result) -> result
      _ -> body
    end
  end

  defp apply_on_payload(body, _opts, _model), do: body

  defp apply_on_response(%Req.Response{} = resp, %{on_response: fun}, model) when is_function(fun, 2) do
    headers = Map.new(resp.headers, fn {k, v} -> {k, v} end)
    fun.(%{status: resp.status, headers: headers}, model)
    :ok
  end

  defp apply_on_response(_resp, _opts, _model), do: :ok

  # --- terminal events ---

  defp emit_done_or_error(state) do
    final = Decoder.finalize(state.decoder)
    send(state.caller, {self(), :event, final})
    state
  end

  defp emit_http_error(state, %Req.Response{status: status, body: body}) do
    emit_error(state, "HTTP #{status}: #{inspect(body)}", :error)
  end

  defp emit_error(state, message, reason) do
    {error_ev, decoder} = Decoder.error(state.decoder, message, reason)
    send(state.caller, {self(), :event, error_ev})
    %{state | decoder: decoder}
  end

  # --- telemetry ---

  defp emit_request_stop(state, start_mono, extras) do
    usage = state.decoder.message.usage

    Telemetry.request_stop(
      state.model,
      %{
        duration: System.monotonic_time() - start_mono,
        input_tokens: usage.input,
        output_tokens: usage.output,
        total_tokens: usage.total_tokens
      },
      Map.merge(%{stop_reason: state.decoder.message.stop_reason}, Map.new(extras))
    )
  end

  defp emit_request_exception(state, start_mono, kind, reason) do
    Telemetry.request_exception(state.model, start_mono, kind, reason)
  end
end
