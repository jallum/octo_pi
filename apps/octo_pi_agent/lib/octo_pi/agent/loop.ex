defmodule OctoPi.Agent.Loop do
  @moduledoc """
  The inner + outer agent loop. Runs as a Task spawned from the
  Session on `prompt` / `continue`. Emits events via
  `OctoPi.Agent.Subscribers.dispatch/2` and builds up a new message
  list from the run; on completion, it `cast`s the final state back
  to the Session, which transitions to idle.

  Scope for `octo-z1d.3`:
    - full turn lifecycle (TurnStart → MessageStart/Update/End →
      ToolExecution* → TurnEnd)
    - sequential tool dispatch only (parallel lands in `octo-z1d.4`)
    - exit conditions (stop_reason terminal, or no tool calls)
    - no steering / follow-up drainage (`octo-z1d.5`)
    - no before/after tool hooks (`octo-z1d.7`)
    - cooperative abort ref checked between turns; hard abort via
      `Task.shutdown` lands in `octo-z1d.6`

  Maintains its own local state during the run. On completion the
  Session's post-run cast is what moves the transcript forward;
  Session's `state/1` won't see in-flight messages.
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.StreamOptions
  alias OctoPi.AI.ToolCall

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
    dispatch(session, %Event.AgentStart{})

    {messages, reason} = loop(session, state, state.messages, abort_ref, 1)

    dispatch(session, %Event.AgentEnd{reason: reason, messages: messages})

    GenServer.cast(session, {:run_complete, messages, reason})

    :ok
  end

  # Outer loop: keep turning until we hit a terminal reason.
  defp loop(session, state, messages, abort_ref, turn) do
    if AbortRef.aborted?(abort_ref) do
      {aborted_messages(messages), :aborted}
    else
      dispatch(session, %Event.TurnStart{turn: turn})
      assistant = stream_turn(session, state, messages)
      updated = messages ++ [assistant]
      dispatch(session, %Event.TurnEnd{turn: turn})

      continue_or_stop(session, state, updated, assistant, abort_ref, turn)
    end
  end

  defp continue_or_stop(_session, _state, updated, %{stop_reason: reason}, _abort_ref, _turn)
       when reason in [:error, :aborted] do
    {updated, reason}
  end

  defp continue_or_stop(session, state, updated, %{stop_reason: :tool_use} = assistant, ref, turn) do
    tool_results =
      execute_tool_calls_sequentially(session, state.tools, assistant.content, ref)

    loop(session, state, updated ++ tool_results, ref, turn + 1)
  end

  defp continue_or_stop(_session, _state, updated, %{stop_reason: reason}, _ref, _turn) do
    {updated, reason}
  end

  # Stream one turn through the configured Transport; collect
  # MessageStart/Update/End events and return the finalized
  # assistant message.
  defp stream_turn(session, state, messages) do
    context = %AIContext{
      system_prompt: state.system_prompt,
      messages: messages,
      tools: Enum.map(state.tools, &agent_tool_to_ai_tool/1)
    }

    stream = state.transport.stream(state.model, context, %StreamOptions{})
    Enum.reduce(stream, nil, &handle_ai_event(session, &1, &2))
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

  defp execute_tool_calls_sequentially(session, tools, content, abort_ref) do
    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))

    Enum.map(tool_calls, fn call ->
      execute_one_tool_call(session, tools, call, abort_ref)
      |> build_tool_result_message(call)
    end)
  end

  defp execute_one_tool_call(session, tools, %ToolCall{} = call, abort_ref) do
    case Enum.find(tools, &(&1.name == call.name)) do
      nil ->
        result = %Tool.Result{
          content: [%OctoPi.AI.Content.Text{text: "tool not registered: #{call.name}"}],
          is_error?: true
        }

        dispatch_tool(session, call, result)
        result

      %Tool{} = tool ->
        dispatch(session, %Event.ToolExecutionStart{
          tool_call_id: call.id,
          tool_name: call.name
        })

        params = prepare_params(tool, call.arguments)

        on_update = fn partial ->
          dispatch(session, %Event.ToolExecutionUpdate{
            tool_call_id: call.id,
            partial: partial
          })
        end

        result =
          try do
            case tool.handler.execute(call.id, params, abort_ref, on_update) do
              {:ok, %Tool.Result{} = r} -> r
              {:error, reason} -> error_result("handler returned {:error, #{inspect(reason)}}")
            end
          rescue
            e -> error_result(Exception.message(e))
          end

        dispatch_tool(session, call, result)
        result
    end
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

  defp aborted_messages(messages) do
    messages ++
      [
        %Assistant{
          api: :octo_pi_agent,
          provider: :octo_pi_agent,
          model: "",
          timestamp: :os.system_time(:millisecond),
          content: [],
          stop_reason: :aborted,
          error_message: "aborted by caller"
        }
      ]
  end

  defp agent_tool_to_ai_tool(%Tool{} = t) do
    %OctoPi.AI.Tool{
      name: t.name,
      description: t.description,
      parameters: t.parameters
    }
  end

  defp dispatch(session, event), do: Subscribers.dispatch(session, event)
end
