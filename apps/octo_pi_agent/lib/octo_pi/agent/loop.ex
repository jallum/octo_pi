defmodule OctoPi.Agent.Loop do
  @moduledoc """
  Per-turn worker. Spawned as a Task by `OctoPi.Agent.Session` for
  each turn of a run; streams one turn through the configured
  Transport, dispatches tools when the assistant stops with
  `:tool_use`, casts subscriber-facing events back to Session as
  they fire, and casts `{:turn_done, assistant, tool_results,
  stop_reason}` at the end before exiting `:normal`.

  Loop holds no multi-turn state — Session owns the transcript, the
  steering / follow-up queues, and the turn counter. Between turns,
  Session decides whether to spawn another Loop and what context to
  hand it.

  Subscriber events flow through Session: per stream-event Loop
  casts `{:agent_event, self(), event}` to Session, which pid-gates
  forwarding so events from a killed/cancelled Loop never reach
  subscribers. Telemetry (`tool:start/stop/error`) emits inline.

  Tool dispatch runs under `OctoPi.Agent.ToolSupervisor` with tasks
  linked to the Loop; a brutal kill from `Session` (hard abort)
  propagates to in-flight tools.
  """

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.ToolCall

  # Upper bound on concurrent tool tasks for a single batch. A
  # pathological model reply with dozens of parallel calls would
  # otherwise spawn one task per call; the cap just protects the
  # scheduler. Any batch larger than this still runs to completion,
  # just in waves.
  @max_tool_concurrency 16

  @type turn_opts :: %{
          required(:session) => pid(),
          required(:abort_ref) => OctoPi.Agent.AbortRef.t(),
          required(:context) => OctoPi.AI.Context.t(),
          required(:model) => OctoPi.AI.Model.t(),
          required(:transport) => module(),
          required(:tools) => [Tool.t()],
          optional(:before_tool_call) => fun() | nil,
          optional(:after_tool_call) => fun() | nil
        }

  @doc """
  Run one turn. Streams the turn through the configured Transport,
  dispatches tools on `:tool_use`, then casts
  `{:turn_done, assistant, tool_results, stop_reason}` to the
  session and exits `:normal`.
  """
  @spec run(turn_opts()) :: :ok
  def run(opts) do
    # Capture the loop's own pid once and thread it through; tool
    # sub-tasks under ToolSupervisor have their own `self()`, so
    # using `self()` directly inside them would break Session's
    # pid-gate on subscriber-event forwarding.
    loop_pid = self()
    opts = Map.put(opts, :loop_pid, loop_pid)

    session = opts.session
    assistant = stream_turn(opts)

    tool_results =
      case assistant.stop_reason do
        :tool_use -> execute_tool_calls(opts, assistant.content)
        _ -> []
      end

    GenServer.cast(
      session,
      {:turn_done, assistant, tool_results, assistant.stop_reason}
    )

    :ok
  end

  # Stream one turn through the configured Transport; collect
  # MessageStart/Update/End events (routed through Session) and
  # return the finalized assistant message. If the stream terminates
  # without emitting Done or Error, synthesize an error assistant.
  defp stream_turn(opts) do
    stream = opts.transport.stream(opts.model, opts.context, %OctoPi.AI.StreamOptions{})

    case Enum.reduce(stream, nil, &handle_ai_event(opts, &1, &2)) do
      %{stop_reason: reason} = assistant when not is_nil(reason) -> assistant
      _partial_or_nil -> truncated_stream_assistant(opts.model)
    end
  end

  defp truncated_stream_assistant(model) do
    %OctoPi.AI.Message.Assistant{
      api: model.api,
      provider: model.provider,
      model: model.id,
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: :error,
      error_message: "stream ended with no terminal event"
    }
  end

  defp handle_ai_event(opts, %AIEvent.Start{partial: p}, _acc) do
    cast_event(opts, %Event.MessageStart{partial: p})
    p
  end

  defp handle_ai_event(opts, %AIEvent.TextDelta{partial: p}, _acc) do
    cast_event(opts, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(opts, %AIEvent.ThinkingDelta{partial: p}, _acc) do
    cast_event(opts, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(opts, %AIEvent.ToolCallDelta{partial: p}, _acc) do
    cast_event(opts, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(opts, %AIEvent.Done{message: msg}, _acc) do
    cast_event(opts, %Event.MessageEnd{message: msg})
    msg
  end

  defp handle_ai_event(opts, %AIEvent.Error{message: msg}, _acc) do
    cast_event(opts, %Event.MessageEnd{message: msg})
    msg
  end

  defp handle_ai_event(_opts, _other, acc), do: acc

  # Dispatch tool calls from the assistant turn. Runs in parallel
  # via `Task.Supervisor.async_stream` (linked) under the
  # `OctoPi.Agent.ToolSupervisor` *unless* any tool in the batch is
  # flagged `:sequential` — in which case the whole batch serializes
  # (ape pi-mono L349). Results are returned in source order.
  defp execute_tool_calls(opts, content) do
    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))

    if any_sequential?(tool_calls, opts.tools) do
      run_sequential(opts, tool_calls)
    else
      run_parallel(opts, tool_calls)
    end
  end

  defp any_sequential?(tool_calls, tools) do
    Enum.any?(tool_calls, fn call ->
      case Enum.find(tools, &(&1.name == call.name)) do
        %Tool{execution_mode: :sequential} -> true
        _ -> false
      end
    end)
  end

  defp run_sequential(opts, tool_calls) do
    Enum.map(tool_calls, fn call ->
      opts
      |> execute_one_tool_call(call)
      |> build_tool_result_message(call)
    end)
  end

  defp run_parallel(opts, tool_calls) do
    OctoPi.Agent.ToolSupervisor
    |> Task.Supervisor.async_stream(
      tool_calls,
      fn call -> {call, execute_one_tool_call(opts, call)} end,
      ordered: true,
      max_concurrency: min(max(length(tool_calls), 1), @max_tool_concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {call, result}} -> build_tool_result_message(result, call) end)
  end

  defp execute_one_tool_call(opts, %ToolCall{} = call) do
    case Enum.find(opts.tools, &(&1.name == call.name)) do
      nil ->
        result = error_result("tool not registered: #{call.name}")
        cast_tool_end(opts, call, result)
        result

      %Tool{} = tool ->
        cast_event(opts, %Event.ToolExecutionStart{
          tool_call_id: call.id,
          tool_name: call.name,
          args: call.arguments
        })

        start_mono = System.monotonic_time()

        :telemetry.execute(
          [:octo_pi_agent, :tool, :start],
          %{system_time: System.system_time()},
          %{tool_call_id: call.id, tool_name: call.name}
        )

        result = dispatch_with_hooks(opts, tool, call)
        cast_tool_end(opts, call, result)
        emit_tool_stop(call, result, start_mono)
        result
    end
  end

  defp dispatch_with_hooks(opts, tool, call) do
    case run_before_hook(opts[:before_tool_call], call) do
      {:block, reason} ->
        error_result("blocked by before_tool_call: #{reason}")

      :allow ->
        result = run_tool_handler(opts, tool, call)
        run_after_hook(opts[:after_tool_call], call, result)
    end
  end

  defp run_tool_handler(opts, tool, call) do
    on_update = fn partial ->
      cast_event(opts, %Event.ToolExecutionUpdate{
        tool_call_id: call.id,
        partial: partial
      })
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

  defp emit_tool_stop(call, %Tool.Result{is_error?: is_error?}, start_mono) do
    event = if is_error?, do: :error, else: :stop

    :telemetry.execute(
      [:octo_pi_agent, :tool, event],
      %{duration: System.monotonic_time() - start_mono},
      %{tool_call_id: call.id, tool_name: call.name, is_error?: is_error?}
    )
  end

  defp cast_tool_end(opts, %ToolCall{} = call, result) do
    cast_event(opts, %Event.ToolExecutionEnd{
      tool_call_id: call.id,
      tool_name: call.name,
      result: result
    })
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

  # Cast a subscriber-facing event to Session for routing, tagged
  # with the *Loop's* pid (captured at run/1). Session pid-gates
  # forwarding so events from a cancelled Loop are dropped — and
  # tool sub-tasks that call this still get the right tag.
  defp cast_event(%{session: session, loop_pid: from}, event),
    do: GenServer.cast(session, {:agent_event, from, event})
end
