defmodule OctoPi.Agent.Turn.Worker do
  @moduledoc """
  Stream and tool-batch worker entry points spawned as Tasks by
  `OctoPi.Agent.Loop`. The two phases of a turn (stream the
  assistant, then dispatch any tool calls) live as separate Task
  invocations driven by the `OctoPi.Agent.Turn` FSM in Loop.

  Lifted from the now-deleted `OctoPi.Agent.Loop`. The behavioral
  contract is identical — same telemetry, same subscriber-event
  shapes, same `Tool.Result` semantics, same parallel/sequential
  dispatch. The only change is the message channel: Loop cast events
  via `GenServer.cast(loop, {:agent_event, pid, event})` and pid-
  gated; the Worker `send/2`s `{:agent_event, ref, event}` and
  Loop ref-gates against the active `turn_ref` set when each Task
  spawned.

  ## Entry points

    * `stream/5` — runs `Enum.reduce(stream, ...)`, sends each AI
      event as `{:agent_event, ref, %Event.MessageStart|...{}}`, then
      finishes with `{:stream_done, ref, %Assistant{}}` or
      `{:stream_failed, ref, reason}` to the parent.
    * `tool_batch/5` — runs the parallel/sequential dispatch (mode
      resolved from tool defs by Loop, passed in via `mode`).
      Sends `{:agent_event, ref, %Event.ToolExecutionStart|...{}}`
      events for each call, then `{:tool_batch_done, ref, results}`.

  Both entry points return `:ok`; Task `:DOWN` reflects abnormal
  exits which Loop also handles via ref-gated `handle_info`.
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.ToolCall

  @max_tool_concurrency 16

  @type stream_opts :: %{
          required(:context) => OctoPi.AI.Context.t(),
          required(:model) => OctoPi.AI.Model.t(),
          required(:transport) => module()
        }

  @type tool_opts :: %{
          required(:abort_ref) => AbortRef.t(),
          required(:tools) => [Tool.t()],
          required(:mode) => :parallel | :sequential,
          optional(:before_tool_call) => fun() | nil,
          optional(:after_tool_call) => fun() | nil,
          optional(:session_id) => String.t() | nil
        }

  # ---------- stream phase ----------

  @doc """
  Stream one turn through the configured Transport. Sends per-event
  `{:agent_event, ref, ...}` messages to `parent` and finishes with
  `{:stream_done, ref, assistant}` (or `{:stream_failed, ref, reason}`
  on a transport error or truncated stream).
  """
  @spec stream(pid(), reference(), stream_opts()) :: :ok
  def stream(parent, ref, %{context: ctx, model: model, transport: transport}) do
    {:ok, producer_pid} = transport.stream_to(model, ctx, [], self())

    final_assistant =
      receive_stream(parent, ref, producer_pid, %{partial: nil, snapshots: %{}})

    assistant =
      case final_assistant do
        %Assistant{stop_reason: r} = a when not is_nil(r) -> a
        _ -> truncated_stream_assistant(model)
      end

    send(parent, {:stream_done, ref, assistant})
    :ok
  rescue
    e ->
      send(parent, {:stream_failed, ref, Exception.message(e)})
      :ok
  end

  defp receive_stream(parent, ref, producer_pid, acc) do
    receive do
      {^producer_pid, :event, event} ->
        receive_stream(parent, ref, producer_pid, handle_ai_event(parent, ref, event, acc))

      {^producer_pid, :done} ->
        acc.partial
    end
  end

  defp handle_ai_event(parent, ref, %AIEvent.Start{partial: p}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageStart{partial: p}})
    %{acc | partial: p}
  end

  defp handle_ai_event(parent, ref, %AIEvent.TextStart{content_index: idx}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageBlockStart{block_id: idx, kind: :text}})
    %{acc | snapshots: Map.put(acc.snapshots, idx, "")}
  end

  defp handle_ai_event(parent, ref, %AIEvent.TextDelta{content_index: idx, delta: delta, partial: p}, acc) do
    snapshot = Map.get(acc.snapshots, idx, "") <> delta

    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockDelta{block_id: idx, kind: :text, delta: delta, snapshot: snapshot}}
    )

    %{acc | partial: p, snapshots: Map.put(acc.snapshots, idx, snapshot)}
  end

  defp handle_ai_event(parent, ref, %AIEvent.TextEnd{content_index: idx, content: content}, acc) do
    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockEnd{block_id: idx, kind: :text, content: content}}
    )

    %{acc | snapshots: Map.put(acc.snapshots, idx, content)}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ThinkingStart{content_index: idx}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageBlockStart{block_id: idx, kind: :thinking}})
    %{acc | snapshots: Map.put(acc.snapshots, idx, "")}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ThinkingDelta{content_index: idx, delta: delta, partial: p}, acc) do
    snapshot = Map.get(acc.snapshots, idx, "") <> delta

    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockDelta{block_id: idx, kind: :thinking, delta: delta, snapshot: snapshot}}
    )

    %{acc | partial: p, snapshots: Map.put(acc.snapshots, idx, snapshot)}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ThinkingEnd{content_index: idx, content: content}, acc) do
    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockEnd{block_id: idx, kind: :thinking, content: content}}
    )

    %{acc | snapshots: Map.put(acc.snapshots, idx, content)}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ToolCallStart{content_index: idx}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageBlockStart{block_id: idx, kind: :tool_call}})
    %{acc | snapshots: Map.put(acc.snapshots, idx, "")}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ToolCallDelta{content_index: idx, delta: delta, partial: p}, acc) do
    snapshot = Map.get(acc.snapshots, idx, "") <> delta

    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockDelta{block_id: idx, kind: :tool_call, delta: delta, snapshot: snapshot}}
    )

    %{acc | partial: p, snapshots: Map.put(acc.snapshots, idx, snapshot)}
  end

  defp handle_ai_event(parent, ref, %AIEvent.ToolCallEnd{content_index: idx}, acc) do
    content = Map.get(acc.snapshots, idx, "")

    send(
      parent,
      {:agent_event, ref,
       %Event.MessageBlockEnd{block_id: idx, kind: :tool_call, content: content}}
    )

    acc
  end

  defp handle_ai_event(parent, ref, %AIEvent.Done{message: msg}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageEnd{message: msg}})
    %{acc | partial: msg}
  end

  defp handle_ai_event(parent, ref, %AIEvent.Error{message: msg}, acc) do
    send(parent, {:agent_event, ref, %Event.MessageEnd{message: msg}})
    %{acc | partial: msg}
  end

  defp handle_ai_event(_parent, _ref, _other, acc), do: acc

  defp truncated_stream_assistant(model) do
    %Assistant{
      api: model.api,
      provider: model.provider,
      model: model.id,
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: :error,
      error_message: "stream ended with no terminal event"
    }
  end

  # ---------- tool batch phase ----------

  @doc """
  Run a tool batch — mode resolved by Loop from tool defs. Sends
  per-tool `{:agent_event, ref, ...}` events, then
  `{:tool_batch_done, ref, results}` to `parent`. `results` is a list
  of `OctoPi.AI.Message.ToolResult` in source order.
  """
  @spec tool_batch(pid(), reference(), tool_opts(), [ToolCall.t()]) :: :ok
  def tool_batch(parent, ref, opts, calls) do
    results =
      case opts.mode do
        :sequential -> run_sequential(parent, ref, opts, calls)
        :parallel -> run_parallel(parent, ref, opts, calls)
      end

    send(parent, {:tool_batch_done, ref, results})
    :ok
  end

  defp run_sequential(parent, ref, opts, calls) do
    Enum.map(calls, fn call ->
      parent
      |> execute_one_tool_call(ref, opts, call)
      |> build_tool_result_message(call)
    end)
  end

  defp run_parallel(parent, ref, opts, calls) do
    OctoPi.Agent.ToolSupervisor
    |> Task.Supervisor.async_stream(
      calls,
      fn call -> {call, execute_one_tool_call(parent, ref, opts, call)} end,
      ordered: true,
      max_concurrency: min(max(length(calls), 1), @max_tool_concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {call, result}} -> build_tool_result_message(result, call) end)
  end

  defp execute_one_tool_call(parent, ref, opts, %ToolCall{} = call) do
    case Enum.find(opts.tools, &(&1.name == call.name)) do
      nil ->
        result = error_result("tool not registered: #{call.name}")
        cast_tool_end(parent, ref, call, result)
        result

      %Tool{} = tool ->
        send(
          parent,
          {:agent_event, ref,
           %Event.ToolExecutionStart{
             tool_call_id: call.id,
             tool_name: call.name,
             args: call.arguments
           }}
        )

        start_mono = System.monotonic_time()

        :telemetry.execute(
          [:octo_pi_agent, :tool, :start],
          %{system_time: System.system_time()},
          %{tool_call_id: call.id, tool_name: call.name, session_id: opts[:session_id]}
        )

        result = dispatch_with_hooks(parent, ref, opts, tool, call)
        cast_tool_end(parent, ref, call, result)
        emit_tool_stop(call, result, start_mono, opts[:session_id])
        result
    end
  end

  defp dispatch_with_hooks(parent, ref, opts, tool, call) do
    case run_before_hook(opts[:before_tool_call], call) do
      {:block, reason} ->
        error_result("blocked by before_tool_call: #{reason}")

      :allow ->
        result = run_tool_handler(parent, ref, opts, tool, call)
        run_after_hook(opts[:after_tool_call], call, result)
    end
  end

  defp run_tool_handler(parent, ref, opts, tool, call) do
    on_update = fn partial ->
      send(
        parent,
        {:agent_event, ref,
         %Event.ToolExecutionUpdate{
           tool_call_id: call.id,
           partial: partial
         }}
      )
    end

    params = prepare_params(tool, call.arguments)

    try do
      case tool.handler.execute(call.id, params, opts.abort_ref, on_update) do
        {:ok, %Tool.Result{} = r} -> r
        {:error, reason} -> error_result("handler returned {:error, #{inspect(reason)}}")
      end
    rescue
      e -> error_result(Exception.message(e))
    end
  end

  defp run_before_hook(nil, _call), do: :allow

  defp run_before_hook(fun, call) when is_function(fun, 1) do
    case fun.(%{id: call.id, name: call.name, arguments: call.arguments}) do
      :allow -> :allow
      {:block, reason} -> {:block, to_string(reason)}
      other -> {:block, "before_tool_call returned #{inspect(other)}"}
    end
  rescue
    e -> {:block, "before_tool_call raised: #{Exception.message(e)}"}
  end

  defp run_after_hook(nil, _call, result), do: result

  defp run_after_hook(fun, call, result) when is_function(fun, 1) do
    ctx = %{id: call.id, name: call.name, arguments: call.arguments, result: result}

    case fun.(ctx) do
      :unchanged -> result
      {:patch, patch} when is_map(patch) -> struct(result, patch)
      other -> error_result("after_tool_call returned #{inspect(other)}")
    end
  rescue
    e -> error_result("after_tool_call raised: #{Exception.message(e)}")
  end

  defp emit_tool_stop(call, %Tool.Result{is_error?: is_error?}, start_mono, session_id) do
    :telemetry.execute(
      [:octo_pi_agent, :tool, :stop],
      %{duration: System.monotonic_time() - start_mono},
      %{tool_call_id: call.id, tool_name: call.name, is_error?: is_error?, session_id: session_id}
    )
  end

  defp cast_tool_end(parent, ref, %ToolCall{} = call, result) do
    send(
      parent,
      {:agent_event, ref,
       %Event.ToolExecutionEnd{
         tool_call_id: call.id,
         tool_name: call.name,
         result: result
       }}
    )
  end

  defp prepare_params(%Tool{prepare_arguments: nil}, args), do: args

  defp prepare_params(%Tool{prepare_arguments: fun}, args) when is_function(fun, 1), do: fun.(args)

  defp build_tool_result_message(%Tool.Result{} = result, %ToolCall{} = call) do
    %OctoPi.AI.Message.ToolResult{
      tool_call_id: call.id,
      tool_name: call.name,
      content: result.content,
      is_error?: result.is_error?,
      details: result.details,
      timestamp: :os.system_time(:millisecond)
    }
  end

  defp error_result(reason) do
    %Tool.Result{
      content: [%OctoPi.AI.Content.Text{text: reason}],
      is_error?: true
    }
  end

  # ---------- mode resolution helper ----------

  @doc """
  Resolve dispatch mode from tool definitions. If any tool in `calls`
  has `:execution_mode == :sequential`, the whole batch serializes —
  matches `Loop.any_sequential?/2` semantics.
  """
  @spec resolve_mode([ToolCall.t()], [Tool.t()]) :: :parallel | :sequential
  def resolve_mode(calls, tools) do
    if Enum.any?(calls, &sequential_tool?(&1, tools)), do: :sequential, else: :parallel
  end

  defp sequential_tool?(call, tools) do
    match?(%Tool{execution_mode: :sequential}, Enum.find(tools, &(&1.name == call.name)))
  end
end
