defmodule OctoPi.AI.Providers.Anthropic.Producer do
  @moduledoc """
  Per-call Anthropic streaming worker.

  Runs as a supervised Task under `OctoPi.AI.Providers.Anthropic.TaskSup`.
  The task:

    1. Emits the `:start` event immediately so the caller sees signs
       of life before any bytes arrive.
    2. Opens the HTTP request with `Req.post!(into: :self)`, receiving
       chunks as messages via `Req.parse_message/2`.
    3. Feeds each chunk through `OctoPi.AI.SSE` → JSON repair →
       `Decoder.handle` and `send/2`s each canonical event to the
       caller.
    4. Emits `Event.Done` or `Event.Error` when the body ends (or a
       known exception surfaces).
    5. Sends a final `:done` sentinel and exits `:normal`.

  State flows as a plain function argument through the `receive_loop`,
  so the rescue path naturally captures the latest in-flight state
  (unlike the previous `Process.put/get` version).

  Lifecycle:

    - Caller halts the stream → `Stream.resource/3`'s `after` fun
      does `Process.exit(pid, :shutdown)`. Task dies; Finch drops the
      connection.
    - Caller dies mid-stream → our `Process.monitor/1` fires inside
      the receive loop; we halt, mark the state aborted, and emit
      `Event.Error{reason: :aborted}`. (Aborted semantics land in
      opi-hgb.2 — this module is wired to support them; currently
      the `aborted?` flag is set but the error surfaces as `:error`.)
    - HTTP 4xx/5xx → `emit_http_error` + `request.stop` telemetry.
    - Known exceptions (Req.TransportError, Jason.DecodeError,
      RuntimeError) are caught, turned into `Event.Error`, telemetry
      fires, and the task exits `:normal`. Everything else bubbles
      to the Task.Supervisor.
  """

  alias OctoPi.AI.{PartialJson, SSE}
  alias OctoPi.AI.Providers.Anthropic.{Auth, Decoder, Request}
  alias OctoPi.AI.SSE.Event, as: SseEvent

  @type start_arg :: %{
          required(:model) => OctoPi.AI.Model.t(),
          required(:context) => OctoPi.AI.Context.t(),
          required(:opts) => OctoPi.AI.StreamOptions.t(),
          required(:caller) => pid(),
          required(:ref) => reference(),
          optional(:req_overrides) => keyword()
        }

  @doc """
  Start a producer task under `OctoPi.AI.Providers.Anthropic.TaskSup`.
  Returns the task pid so the caller can monitor / halt it.
  """
  @spec start(start_arg()) :: {:ok, pid()} | {:error, term()}
  def start(%{} = args) do
    Task.Supervisor.start_child(
      OctoPi.AI.Providers.Anthropic.TaskSup,
      fn -> run(args) end,
      restart: :temporary
    )
  end

  @spec run(start_arg()) :: :ok
  def run(%{} = args) do
    caller_mon = Process.monitor(args.caller)
    auth = Auth.resolve(args.opts)
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:octo_pi_ai, :anthropic, :request, :start],
      %{system_time: System.system_time()},
      %{model: args.model.id, auth_type: auth.type}
    )

    {start_event, decoder_state} =
      Decoder.new(args.model, oauth?: auth.type == :oauth, tools: args.context.tools)

    send(args.caller, {args.ref, :event, start_event})

    state = %{
      caller: args.caller,
      ref: args.ref,
      caller_mon: caller_mon,
      model: args.model,
      sse: SSE.new(),
      decoder: decoder_state,
      aborted?: false
    }

    req_spec = Request.build(args.model, args.context, args.opts, auth)

    req_opts =
      [
        url: req_spec.url,
        headers: req_spec.headers,
        json: req_spec.body,
        receive_timeout: :infinity,
        into: :self
      ] ++ Map.get(args, :req_overrides, [])

    state =
      try do
        resp = Req.post!(req_opts)
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
        e in [Req.TransportError, Jason.DecodeError, RuntimeError] ->
          state = emit_error(state, Exception.message(e), :error)
          emit_request_exception(state, start_mono, :error, Exception.message(e))
          state
      end

    send(state.caller, {state.ref, :done})
    :ok
  end

  # --- body drain: receive chunks via Req.parse_message/2 ---

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
    decoder = apply_sse_events(sse_events, state.decoder, state.caller, state.ref)
    %{state | sse: sse, decoder: decoder}
  end

  # Flush any trailing SSE event that the server closed the stream
  # before delimiting (matches pi-mono's iterateSseMessages EOF
  # behaviour; see SSE.finalize/1).
  defp flush_sse(state) do
    {sse_events, sse} = SSE.finalize(state.sse)
    decoder = apply_sse_events(sse_events, state.decoder, state.caller, state.ref)
    %{state | sse: sse, decoder: decoder}
  end

  defp apply_sse_events(sse_events, decoder, caller, ref) do
    Enum.reduce(sse_events, decoder, fn sse_ev, dstate ->
      handle_sse_event(sse_ev, dstate, caller, ref)
    end)
  end

  defp handle_sse_event(%SseEvent{event: "ping"}, dstate, _caller, _ref), do: dstate

  defp handle_sse_event(%SseEvent{event: "error", data: data}, _dstate, _caller, _ref) do
    raise "Anthropic SSE error: #{data}"
  end

  defp handle_sse_event(%SseEvent{data: data}, dstate, caller, ref) do
    case PartialJson.parse_with_repair(data) do
      {:ok, event} when is_map(event) ->
        {events, dstate} = Decoder.handle(dstate, event)
        Enum.each(events, &send(caller, {ref, :event, &1}))
        dstate

      _ ->
        # Malformed SSE frame — skip silently.
        dstate
    end
  end

  # --- terminal events ---

  defp emit_done_or_error(state) do
    final = Decoder.finalize(state.decoder)
    send(state.caller, {state.ref, :event, final})
    state
  end

  defp emit_http_error(state, %Req.Response{status: status, body: body}) do
    emit_error(state, "HTTP #{status}: #{inspect(body)}", :error)
  end

  defp emit_error(state, message, reason) do
    {error_ev, decoder} = Decoder.error(state.decoder, message, reason)
    send(state.caller, {state.ref, :event, error_ev})
    %{state | decoder: decoder}
  end

  # --- telemetry ---

  defp emit_request_stop(state, start_mono, extras) do
    usage = state.decoder.message.usage

    :telemetry.execute(
      [:octo_pi_ai, :anthropic, :request, :stop],
      %{
        duration: System.monotonic_time() - start_mono,
        input_tokens: usage.input,
        output_tokens: usage.output,
        total_tokens: usage.total_tokens
      },
      Map.merge(
        %{model: state.model.id, stop_reason: state.decoder.message.stop_reason},
        Map.new(extras)
      )
    )
  end

  defp emit_request_exception(state, start_mono, kind, reason) do
    :telemetry.execute(
      [:octo_pi_ai, :anthropic, :request, :exception],
      %{duration: System.monotonic_time() - start_mono},
      %{model: state.model.id, kind: kind, reason: reason}
    )
  end
end
