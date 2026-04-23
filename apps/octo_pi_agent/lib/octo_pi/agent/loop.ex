defmodule OctoPi.Agent.Loop do
  @moduledoc """
  The inner + outer agent loop. Runs as a Task spawned from the
  Session on `prompt`/`continue`. Drives turns until a terminal
  stop reason, emitting agent events via
  `OctoPi.Agent.Subscribers.dispatch/2` and building up a new
  message list as it goes; on completion it casts
  `{:run_complete, messages, reason}` back to the Session.

  Control flow per iteration:

    1. Cooperative abort check (ETS flag on `AbortRef`).
    2. Drain the steering queue (skipped on turn 1).
    3. Stream one turn through the configured Transport.
    4. If `stop_reason` is `:tool_use`, dispatch tool calls
       (parallel via `Task.Supervisor.async_stream` unless any tool
       is `:sequential`), then loop. If terminal, drain the
       follow-up queue — if it yielded messages, loop; otherwise
       exit.

  Tool dispatch runs under `OctoPi.Agent.ToolSupervisor` with tasks
  linked to the loop so a brutal-kill from `Session` (hard abort)
  propagates to in-flight tools. Tool hooks (`before_tool_call`,
  `after_tool_call`) wrap each handler invocation; exceptions in
  hooks or handlers fold into error results so the loop keeps
  running.

  Maintains its own local state during the run; the Session's
  `state/1` does not see in-flight messages until `:run_complete`
  lands.
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.StreamOptions
  alias OctoPi.AI.ToolCall

  # Upper bound on concurrent tool tasks for a single batch. A
  # pathological model reply with dozens of parallel calls would
  # otherwise spawn one task per call; the cap just protects the
  # scheduler. Any batch larger than this still runs to completion,
  # just in waves.
  @max_tool_concurrency 16

  @type run_opts :: %{
          required(:session) => pid(),
          required(:session_state) => OctoPi.Agent.Session.State.t(),
          required(:abort_ref) => AbortRef.t()
        }

  @doc """
  Entry point for a run. Emits `AgentStart`, drives turns until a
  terminal stop reason, emits `AgentEnd`, then casts
  `{:run_complete, messages, reason}` back to the Session.

  Returns `:ok` on clean exit.
  """
  @spec run(run_opts()) :: :ok
  def run(%{session: session, session_state: state, abort_ref: abort_ref}) do
    :telemetry.execute(
      [:octo_pi_agent, :session, :start],
      %{system_time: System.system_time()},
      %{model: state.model.id}
    )

    dispatch(session, %Event.AgentStart{})

    {messages, reason} = loop(session, state, state.messages, abort_ref, 1)

    dispatch(session, %Event.AgentEnd{reason: reason, messages: messages})
    # Session owns the paired [:session, :stop] telemetry emission so
    # both the clean-exit (run_complete cast) and abnormal-exit
    # (:DOWN) paths flow through the same code.
    GenServer.cast(session, {:run_complete, messages, reason})

    :ok
  end

  # Outer loop: keep turning until we hit a terminal reason.
  # At the top of each iteration we drain the session's steering
  # queue and fold any drained messages into the transcript before
  # the next LLM call.
  defp loop(session, state, messages, abort_ref, turn) do
    if AbortRef.aborted?(abort_ref) do
      {aborted_messages(messages), :aborted}
    else
      messages = drain_steering_after_first_turn(session, messages, turn)
      start_mono = System.monotonic_time()

      :telemetry.execute(
        [:octo_pi_agent, :turn, :start],
        %{system_time: System.system_time()},
        %{turn: turn}
      )

      dispatch(session, %Event.TurnStart{turn: turn})
      assistant = stream_turn(session, state, messages)
      updated = messages ++ [assistant]
      dispatch(session, %Event.TurnEnd{turn: turn})

      :telemetry.execute(
        [:octo_pi_agent, :turn, :stop],
        %{duration: System.monotonic_time() - start_mono},
        %{turn: turn, stop_reason: assistant.stop_reason}
      )

      continue_or_stop(session, state, updated, assistant, abort_ref, turn)
    end
  end

  defp continue_or_stop(_session, _state, updated, %{stop_reason: reason}, _abort_ref, _turn)
       when reason in [:error, :aborted] do
    {updated, reason}
  end

  defp continue_or_stop(session, state, updated, %{stop_reason: :tool_use} = assistant, ref, turn) do
    tool_results = execute_tool_calls(session, state, assistant.content, ref)
    loop(session, state, updated ++ tool_results, ref, turn + 1)
  end

  # Terminal stop — drain the follow-up queue. If anything was
  # queued, fold it in and keep looping; otherwise exit with the
  # stop reason.
  defp continue_or_stop(session, state, updated, %{stop_reason: reason}, abort_ref, turn) do
    case Session.drain_follow_up(session) do
      [] -> {updated, reason}
      followups -> loop(session, state, updated ++ followups, abort_ref, turn + 1)
    end
  end

  # Turn 1's messages are the initial transcript — no steering to
  # drain yet. Skipping the round-trip avoids a no-op GenServer.call.
  defp drain_steering_after_first_turn(_session, messages, 1), do: messages

  defp drain_steering_after_first_turn(session, messages, _turn),
    do: messages ++ Session.drain_steering(session)

  # Stream one turn through the configured Transport; collect
  # MessageStart/Update/End events and return the finalized
  # assistant message. If the stream terminates without emitting
  # Done or Error, synthesize an error assistant rather than folding
  # `nil` into the transcript.
  defp stream_turn(session, state, messages) do
    context = %AIContext{
      system_prompt: state.system_prompt,
      messages: messages,
      tools: Enum.map(state.tools, &agent_tool_to_ai_tool/1)
    }

    stream = state.transport.stream(state.model, context, %StreamOptions{})

    case Enum.reduce(stream, nil, &handle_ai_event(session, &1, &2)) do
      %{stop_reason: reason} = assistant when not is_nil(reason) -> assistant
      _partial_or_nil -> truncated_stream_assistant(state)
    end
  end

  defp truncated_stream_assistant(state) do
    %OctoPi.AI.Message.Assistant{
      api: state.model.api,
      provider: state.model.provider,
      model: state.model.id,
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: :error,
      error_message: "stream ended with no terminal event"
    }
  end

  defp handle_ai_event(session, %AIEvent.Start{partial: p}, _acc) do
    dispatch(session, %Event.MessageStart{partial: p})
    p
  end

  defp handle_ai_event(session, %AIEvent.TextDelta{partial: p}, _acc) do
    dispatch(session, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(session, %AIEvent.ThinkingDelta{partial: p}, _acc) do
    dispatch(session, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(session, %AIEvent.ToolCallDelta{partial: p}, _acc) do
    dispatch(session, %Event.MessageUpdate{partial: p})
    p
  end

  defp handle_ai_event(session, %AIEvent.Done{message: msg}, _acc) do
    dispatch(session, %Event.MessageEnd{message: msg})
    msg
  end

  defp handle_ai_event(session, %AIEvent.Error{message: msg}, _acc) do
    dispatch(session, %Event.MessageEnd{message: msg})
    msg
  end

  defp handle_ai_event(_session, _other, acc), do: acc

  # Dispatch tool calls from the assistant turn. Runs in parallel
  # via `Task.Supervisor.async_stream` (linked) under the
  # `OctoPi.Agent.ToolSupervisor` *unless* any tool in the batch is
  # flagged `:sequential` — in which case the whole batch serializes
  # (ape pi-mono L349). Results are returned in source order.
  defp execute_tool_calls(session, state, content, abort_ref) do
    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))

    if any_sequential?(tool_calls, state.tools) do
      run_sequential(session, state, tool_calls, abort_ref)
    else
      run_parallel(session, state, tool_calls, abort_ref)
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

  defp run_sequential(session, state, tool_calls, abort_ref) do
    Enum.map(tool_calls, fn call ->
      execute_one_tool_call(session, state, call, abort_ref)
      |> build_tool_result_message(call)
    end)
  end

  defp run_parallel(session, state, tool_calls, abort_ref) do
    OctoPi.Agent.ToolSupervisor
    |> Task.Supervisor.async_stream(
      tool_calls,
      fn call -> {call, execute_one_tool_call(session, state, call, abort_ref)} end,
      ordered: true,
      max_concurrency: min(max(length(tool_calls), 1), @max_tool_concurrency),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, {call, result}} -> build_tool_result_message(result, call) end)
  end

  defp execute_one_tool_call(session, state, %ToolCall{} = call, abort_ref) do
    case Enum.find(state.tools, &(&1.name == call.name)) do
      nil ->
        result = error_result("tool not registered: #{call.name}")
        dispatch_tool(session, call, result)
        result

      %Tool{} = tool ->
        dispatch(session, %Event.ToolExecutionStart{
          tool_call_id: call.id,
          tool_name: call.name
        })

        start_mono = System.monotonic_time()

        :telemetry.execute(
          [:octo_pi_agent, :tool, :start],
          %{system_time: System.system_time()},
          %{tool_call_id: call.id, tool_name: call.name}
        )

        result = dispatch_with_hooks(session, state, tool, call, abort_ref)
        dispatch_tool(session, call, result)
        emit_tool_stop(call, result, start_mono)
        result
    end
  end

  # Run the before-hook (may block), execute the tool on `:allow`,
  # then run the after-hook (may patch). All exceptions from hooks
  # or the handler are caught and folded into an error result so the
  # loop keeps running.
  defp dispatch_with_hooks(session, state, tool, call, abort_ref) do
    case run_before_hook(state.before_tool_call, call) do
      {:block, reason} ->
        error_result("blocked by before_tool_call: #{reason}")

      :allow ->
        result = run_tool_handler(session, tool, call, abort_ref)
        run_after_hook(state.after_tool_call, call, result)
    end
  end

  defp run_tool_handler(session, tool, call, abort_ref) do
    on_update = fn partial ->
      dispatch(session, %Event.ToolExecutionUpdate{
        tool_call_id: call.id,
        partial: partial
      })
    end

    params = prepare_params(tool, call.arguments)

    try do
      case tool.handler.execute(call.id, params, abort_ref, on_update) do
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

  defp dispatch_tool(session, %ToolCall{} = call, result) do
    dispatch(session, %Event.ToolExecutionEnd{
      tool_call_id: call.id,
      tool_name: call.name,
      result: result
    })
  end

  defp prepare_params(%Tool{prepare_arguments: nil}, args), do: args

  defp prepare_params(%Tool{prepare_arguments: fun}, args) when is_function(fun, 1),
    do: fun.(args)

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

  defp aborted_messages(messages), do: messages ++ [Session.aborted_assistant()]

  defp agent_tool_to_ai_tool(%Tool{} = t) do
    %OctoPi.AI.Tool{
      name: t.name,
      description: t.description,
      parameters: t.parameters
    }
  end

  defp dispatch(session, event), do: Subscribers.dispatch(session, event)
end
