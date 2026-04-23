defmodule OctoPi.AI.Providers.Anthropic.Producer do
  @moduledoc """
  GenServer that drives a single Anthropic streaming request.

  One producer per `stream/3` call. The producer:
    1. Emits the `:start` event immediately.
    2. Runs `Req.post` with a streaming callback that feeds each
       chunk through `OctoPi.AI.SSE` → JSON parse → `Decoder.handle`
       and sends each canonical event as a message to the caller.
    3. Emits `Event.Done` or `Event.Error` when the HTTP body ends
       (or raises).
    4. Sends a final `:done` sentinel and exits with `:normal`.

  Started unlinked via `GenServer.start/3`; the caller monitors the
  pid. Process lifecycle:

    - Caller halts the stream → `Stream.resource/3` `after` fun
      does `Process.exit(pid, :shutdown)`. Producer dies immediately;
      Finch releases the HTTP connection.
    - Caller dies mid-stream → Producer's `Process.monitor/1` fires
      inside the chunk callback; Req is halted, producer exits
      cleanly.
    - HTTP / SSE error → catch, emit `Event.Error`, send `:done`,
      exit `:normal`.

  All events reach the caller via `send/2` using the ref passed at
  init, so callers only need one `receive` clause per message shape.
  """

  use GenServer

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

  @spec start(start_arg()) :: {:ok, pid()} | {:error, term()}
  def start(%{} = args) do
    GenServer.start(__MODULE__, args)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(args) do
    caller_mon = Process.monitor(args.caller)

    state = %{
      model: args.model,
      context: args.context,
      opts: args.opts,
      caller: args.caller,
      ref: args.ref,
      caller_mon: caller_mon,
      req_overrides: Map.get(args, :req_overrides, []),
      sse: SSE.new(),
      decoder: nil
    }

    {:ok, state, {:continue, :run}}
  end

  @impl true
  def handle_continue(:run, state) do
    auth = Auth.resolve(state.opts)
    start_mono = System.monotonic_time()

    :telemetry.execute(
      [:octo_pi_ai, :anthropic, :request, :start],
      %{system_time: System.system_time()},
      %{model: state.model.id, auth_type: auth.type}
    )

    {start_event, decoder_state} =
      Decoder.new(state.model, oauth?: auth.type == :oauth, tools: state.context.tools)

    send(state.caller, {state.ref, :event, start_event})
    state = %{state | decoder: decoder_state}

    req_spec = Request.build(state.model, state.context, state.opts, auth)

    # Stash mutable state in the process dictionary so the Req
    # callback — which only sees (chunk, {req, resp}) — can share
    # state with the GenServer loop.
    Process.put(:octo_pi_state, state)

    req_opts =
      [
        url: req_spec.url,
        headers: req_spec.headers,
        json: req_spec.body,
        receive_timeout: :infinity,
        into: &handle_chunk/2
      ] ++ state.req_overrides

    state =
      try do
        resp = Req.post!(req_opts)

        state = Process.get(:octo_pi_state)

        state =
          if resp.status in 200..299 do
            emit_done_or_error(state)
          else
            emit_http_error(state, resp)
          end

        emit_request_stop(state, start_mono, http_status: resp.status)
        state
      rescue
        e ->
          state = Process.get(:octo_pi_state)
          state = emit_error(state, Exception.message(e), :error)
          emit_request_exception(state, start_mono, :error, Exception.message(e))
          state
      catch
        :exit, reason ->
          state = Process.get(:octo_pi_state)
          state = emit_error(state, "process exit: #{inspect(reason)}", :error)
          emit_request_exception(state, start_mono, :exit, inspect(reason))
          state
      end

    send(state.caller, {state.ref, :done})
    {:stop, :normal, state}
  end

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

  # --- chunk callback (runs inside handle_continue, same process) ---

  defp handle_chunk({:data, chunk}, acc) do
    state = Process.get(:octo_pi_state)

    # Peek for caller-death; if present, halt Req so the connection
    # closes promptly.
    receive do
      {:DOWN, mon, :process, _, _} when mon == state.caller_mon ->
        {:halt, acc}
    after
      0 ->
        process_chunk(chunk, state, acc)
    end
  end

  defp process_chunk(chunk, state, acc) do
    {sse_events, sse} = SSE.decode(state.sse, chunk)

    decoder =
      Enum.reduce(sse_events, state.decoder, fn sse_ev, dstate ->
        handle_sse_event(sse_ev, dstate, state.caller, state.ref)
      end)

    Process.put(:octo_pi_state, %{state | sse: sse, decoder: decoder})
    {:cont, acc}
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
end
