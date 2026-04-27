defmodule OctoPi.Agent.Session do
  @moduledoc """
  Per-session GenServer owning the transcript, queues, tools,
  subscribers, and turn iteration. Called via the `OctoPi.Agent`
  facade; no one should import this module directly.

  Drives the run as a sequence of per-turn `OctoPi.Agent.Loop` Tasks.
  Each turn: Session builds the prompt context and spawns a Loop
  Task, which streams the turn, dispatches tools when the assistant
  stops with `:tool_use`, casts subscriber-facing events back to
  Session for routing, and casts
  `{:turn_done, assistant, tool_results, stop_reason}` before
  exiting `:normal`.

  On `:turn_done`, Session appends the assistant + tool results to
  the transcript, drains the appropriate queue (steering on
  `:tool_use`; follow-up on terminal stop), and either spawns the
  next turn or ends the run.

  Subscriber routing is pid-gated against `loop_task`: events from
  a killed/cancelled Loop never reach subscribers.

  State invariants:

    - `is_streaming?` is `true` iff a run is in flight.
    - `loop_task` is the pid of the *current turn's* Loop, or nil.
    - `abort_ref` is the current run's ref (nil when idle).
    - `run_started_at_mono` is the monotonic start time of the
      current run, nil when idle.
  """

  use GenServer

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.MessageLog
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Transport
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User

  @type mode :: :sync | :async

  # ---------- public API ----------

  @doc false
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc false
  def prompt(pid, msg_or_msgs) do
    GenServer.call(pid, {:prompt, List.wrap(normalize(msg_or_msgs))})
  end

  @doc false
  def continue(pid), do: GenServer.call(pid, :continue)

  @doc false
  def steer(pid, msg), do: GenServer.call(pid, {:steer, normalize(msg)})

  @doc false
  def follow_up(pid, msg), do: GenServer.call(pid, {:follow_up, normalize(msg)})

  @doc false
  def set_queue_mode(pid, queue, mode) when queue in [:steering, :follow_up] and mode in [:one_at_a_time, :all] do
    GenServer.call(pid, {:set_queue_mode, queue, mode})
  end

  @doc false
  def set_thinking_level(pid, level), do: GenServer.call(pid, {:set_thinking_level, level})

  @doc false
  def set_model(pid, model), do: GenServer.call(pid, {:set_model, model})

  @doc false
  def add_tool(pid, tool), do: GenServer.call(pid, {:add_tool, tool})

  @doc false
  def drain_steering(pid), do: GenServer.call(pid, :drain_steering)

  @doc false
  def drain_follow_up(pid), do: GenServer.call(pid, :drain_follow_up)

  @doc false
  def abort(pid), do: GenServer.call(pid, :abort)

  @doc false
  def state(pid), do: GenServer.call(pid, :state)

  @doc false
  def wait_for_idle(pid, timeout), do: GenServer.call(pid, :wait_for_idle, timeout)

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    state =
      %Session.State{
        model: Keyword.fetch!(opts, :model),
        system_prompt: Keyword.get(opts, :system_prompt),
        tools: Keyword.get(opts, :tools, []),
        thinking_level: Keyword.get(opts, :thinking_level, :off),
        transport: Keyword.get(opts, :transport, Transport.Direct),
        before_tool_call: Keyword.get(opts, :before_tool_call),
        after_tool_call: Keyword.get(opts, :after_tool_call),
        messages_provider: Keyword.get(opts, :messages_provider),
        messages: MessageLog.new(Keyword.get(opts, :messages, []))
      }
      |> maybe_override_queue(:steering_queue, opts[:steering_queue_bound])
      |> maybe_override_queue(:follow_up_queue, opts[:follow_up_queue_bound])

    {:ok,
     %{
       session: state,
       idle_waiters: [],
       turn: 0,
       turn_started_at_mono: nil
     }}
  end

  defp maybe_override_queue(state, _field, nil), do: state

  defp maybe_override_queue(state, field, bound) do
    mode = Map.fetch!(state, field).mode
    Map.put(state, field, PendingMessageQueue.new(mode, bound))
  end

  @impl true
  def handle_call({:prompt, msgs}, _from, store) do
    if store.session.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      session = %{store.session | messages: MessageLog.append_many(store.session.messages, msgs)}
      {:reply, :ok, start_run(%{store | session: session})}
    end
  end

  def handle_call(:continue, _from, store) do
    if store.session.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      {:reply, :ok, start_run(store)}
    end
  end

  def handle_call({:steer, msg}, _from, store) do
    case PendingMessageQueue.enqueue(store.session.steering_queue, msg) do
      {:ok, q} -> {:reply, :ok, put_in(store.session.steering_queue, q)}
      {:error, :full} = err -> {:reply, err, store}
    end
  end

  def handle_call({:follow_up, msg}, _from, store) do
    case PendingMessageQueue.enqueue(store.session.follow_up_queue, msg) do
      {:ok, q} -> {:reply, :ok, put_in(store.session.follow_up_queue, q)}
      {:error, :full} = err -> {:reply, err, store}
    end
  end

  def handle_call({:set_queue_mode, :steering, mode}, _from, store),
    do: {:reply, :ok, put_in(store.session.steering_queue.mode, mode)}

  def handle_call({:set_queue_mode, :follow_up, mode}, _from, store),
    do: {:reply, :ok, put_in(store.session.follow_up_queue.mode, mode)}

  def handle_call({:set_thinking_level, level}, _from, store),
    do: {:reply, :ok, put_in(store.session.thinking_level, level)}

  def handle_call({:set_model, model}, _from, store),
    do: {:reply, :ok, put_in(store.session.model, model)}

  def handle_call({:add_tool, tool}, _from, store) do
    tools = store.session.tools
    new_tools = if Enum.any?(tools, &(&1.name == tool.name)), do: tools, else: tools ++ [tool]
    {:reply, :ok, put_in(store.session.tools, new_tools)}
  end

  def handle_call(:drain_steering, _from, store) do
    {msgs, q} = PendingMessageQueue.drain(store.session.steering_queue)
    {:reply, msgs, put_in(store.session.steering_queue, q)}
  end

  def handle_call(:drain_follow_up, _from, store) do
    {msgs, q} = PendingMessageQueue.drain(store.session.follow_up_queue)
    {:reply, msgs, put_in(store.session.follow_up_queue, q)}
  end

  def handle_call(:abort, _from, store) do
    if store.session.is_streaming? do
      # Brutal-kill the current turn's Loop and wind the run down
      # inline:
      #   1. Flip ETS abort flag (cooperative backstop for tools).
      #   2. Process.exit(loop_task, :kill) — linked tool tasks under
      #      ToolSupervisor die with it.
      #   3. Clear loop_task immediately so any in-flight
      #      `:agent_event` casts from the dying Loop fail the
      #      pid-gate and never reach subscribers.
      #   4. Synthesize aborted assistant + AgentEnd, emit
      #      session:stop telemetry, flip idle.
      # The `:DOWN` for the killed Loop arrives later; by then
      # loop_task is nil and the handler is a no-op (or a new run
      # has started with a different pid).
      if store.session.abort_ref, do: AbortRef.abort(store.session.abort_ref)

      if is_pid(store.session.loop_task) and Process.alive?(store.session.loop_task) do
        Process.exit(store.session.loop_task, :kill)
      end

      store = put_in(store.session.loop_task, nil)
      {:reply, :ok, end_run_aborted(store, :killed)}
    else
      {:reply, :ok, store}
    end
  end

  def handle_call(:state, _from, store), do: {:reply, store.session, store}

  def handle_call(:wait_for_idle, from, store) do
    if store.session.is_streaming? do
      {:noreply, %{store | idle_waiters: [from | store.idle_waiters]}}
    else
      {:reply, :ok, store}
    end
  end

  @impl true
  # Subscriber-facing event from a Loop turn. Forward only when it
  # came from the *current* loop_task; events from a cancelled /
  # killed Loop are dropped.
  def handle_cast({:agent_event, from_pid, event}, store) do
    if from_pid == store.session.loop_task do
      Subscribers.dispatch(self(), event)
    end

    {:noreply, store}
  end

  # A turn finished cleanly. Append assistant + tool_results, decide
  # whether to spawn the next turn or end the run.
  def handle_cast({:turn_done, _assistant, _tool_results, _reason}, %{session: %{loop_task: nil}} = store) do
    # Loop_task was cleared (e.g., abort raced with turn_done arrival).
    # Drop the cast — the abort path's :DOWN handler is in charge of
    # the wind-down.
    {:noreply, store}
  end

  def handle_cast({:turn_done, assistant, tool_results, reason}, store) do
    emit_turn_stop(store, reason)

    Subscribers.dispatch(self(), %Event.TurnEnd{turn: store.turn})

    messages =
      store.session.messages
      |> MessageLog.push(assistant)
      |> MessageLog.append_many(tool_results)

    store = put_in(store.session.messages, messages)

    case decide_next(reason, store) do
      {:continue, store} -> {:noreply, spawn_turn(store)}
      {:terminate, store} -> {:noreply, end_run(store, reason)}
    end
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, reason}, store) do
    cond do
      pid == store.session.loop_task ->
        # Loop died abnormally before casting :turn_done. Clear
        # loop_task, synthesize an aborted assistant + AgentEnd, and
        # end the run.
        store = put_in(store.session.loop_task, nil)
        {:noreply, end_run_aborted(store, reason)}

      true ->
        {:noreply, store}
    end
  end

  def handle_info(_msg, store), do: {:noreply, store}

  # ---------- run / turn lifecycle ----------

  defp start_run(store) do
    abort_ref = AbortRef.new()

    :telemetry.execute(
      [:octo_pi_agent, :session, :start],
      %{system_time: System.system_time()},
      %{model: store.session.model.id}
    )

    Subscribers.dispatch(self(), %Event.AgentStart{})

    session = %{
      store.session
      | is_streaming?: true,
        error_message: nil,
        abort_ref: abort_ref,
        run_started_at_mono: System.monotonic_time()
    }

    spawn_turn(%{store | session: session, turn: 0})
  end

  # Decide whether to continue or terminate after a turn.
  # On :tool_use, drain the steering queue and fold drained
  # messages into the transcript before spawning the next turn.
  # On a terminal stop reason, drain the follow-up queue; non-empty
  # → fold + spawn next turn; empty → terminate.
  # On :error / :aborted → terminate.
  defp decide_next(reason, store) when reason in [:error, :aborted], do: {:terminate, store}

  defp decide_next(:tool_use, store) do
    {steers, q} = PendingMessageQueue.drain(store.session.steering_queue)

    store =
      store
      |> put_in([Access.key(:session), Access.key(:steering_queue)], q)
      |> put_in(
        [Access.key(:session), Access.key(:messages)],
        MessageLog.append_many(store.session.messages, steers)
      )

    {:continue, store}
  end

  defp decide_next(_terminal_reason, store) do
    {followups, q} = PendingMessageQueue.drain(store.session.follow_up_queue)

    case followups do
      [] ->
        {:terminate, store}

      msgs ->
        store =
          store
          |> put_in([Access.key(:session), Access.key(:follow_up_queue)], q)
          |> put_in(
            [Access.key(:session), Access.key(:messages)],
            MessageLog.append_many(store.session.messages, msgs)
          )

        {:continue, store}
    end
  end

  defp spawn_turn(store) do
    turn = store.turn + 1
    context = build_turn_context(store.session)

    Subscribers.dispatch(self(), %Event.TurnStart{turn: turn})

    :telemetry.execute(
      [:octo_pi_agent, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: turn}
    )

    session_pid = self()
    session = store.session

    {:ok, pid} =
      Task.Supervisor.start_child(
        OctoPi.Agent.LoopSupervisor,
        fn ->
          Loop.run(%{
            session: session_pid,
            abort_ref: session.abort_ref,
            context: context,
            model: session.model,
            transport: session.transport,
            tools: session.tools,
            before_tool_call: session.before_tool_call,
            after_tool_call: session.after_tool_call
          })
        end,
        restart: :temporary
      )

    Process.monitor(pid)

    %{
      store
      | session: %{session | loop_task: pid},
        turn: turn,
        turn_started_at_mono: System.monotonic_time()
    }
  end

  # Per-turn LLM context. When a `messages_provider` closure is set
  # (the coder app wires one in to call
  # `Coder.Session.build_session_context/1` |>
  # `Coder.Session.Messages.to_llm/1` for post-compaction kept-window
  # assembly), the closure produces the messages list. Otherwise
  # falls back to `MessageLog.to_list/1` so the Agent app stays
  # runnable standalone.
  defp build_turn_context(session) do
    messages =
      case session.messages_provider do
        nil -> MessageLog.to_list(session.messages)
        fun when is_function(fun, 1) -> fun.(session)
      end

    %AIContext{
      system_prompt: session.system_prompt,
      messages: messages,
      tools: Enum.map(session.tools, &agent_tool_to_ai_tool/1)
    }
  end

  defp end_run(store, reason) do
    Subscribers.dispatch(self(), %Event.AgentEnd{
      reason: reason,
      messages: MessageLog.to_list(store.session.messages)
    })

    emit_session_stop(store.session, reason, MessageLog.count(store.session.messages))
    flip_idle(store)
  end

  defp end_run_aborted(store, :normal) do
    # Loop exited :normal without casting :turn_done — shouldn't
    # happen in practice (a clean Loop run always casts), but be
    # defensive: just flip idle without touching the transcript.
    flip_idle(store)
  end

  defp end_run_aborted(store, _reason) do
    messages = MessageLog.push(store.session.messages, aborted_assistant())

    Subscribers.dispatch(self(), %Event.AgentEnd{
      reason: :aborted,
      messages: MessageLog.to_list(messages)
    })

    emit_session_stop(store.session, :aborted, MessageLog.count(messages))

    store = put_in(store.session.messages, messages)
    store = put_in(store.session.error_message, "aborted by caller")
    flip_idle(store)
  end

  defp flip_idle(store) do
    session = %{
      store.session
      | is_streaming?: false,
        abort_ref: maybe_forget_ref(store.session.abort_ref),
        loop_task: nil,
        run_started_at_mono: nil
    }

    store = %{store | session: session, turn: 0, turn_started_at_mono: nil}

    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  @doc false
  @spec aborted_assistant() :: Assistant.t()
  def aborted_assistant do
    %Assistant{
      api: :octo_pi_agent,
      provider: :octo_pi_agent,
      model: "",
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: :aborted,
      error_message: "aborted by caller"
    }
  end

  defp emit_session_stop(%Session.State{run_started_at_mono: nil}, _reason, _turn_count), do: :ok

  defp emit_session_stop(%Session.State{} = state, reason, turn_count) do
    :telemetry.execute(
      [:octo_pi_agent, :session, :stop],
      %{duration: System.monotonic_time() - state.run_started_at_mono},
      %{reason: reason, turn_count: turn_count}
    )
  end

  defp emit_turn_stop(%{turn_started_at_mono: nil}, _reason), do: :ok

  defp emit_turn_stop(%{turn: turn, turn_started_at_mono: started}, reason) do
    :telemetry.execute(
      [:octo_pi_agent, :turn, :stop],
      %{duration: System.monotonic_time() - started},
      %{turn: turn, stop_reason: reason}
    )
  end

  defp maybe_forget_ref(nil), do: nil

  defp maybe_forget_ref(ref) do
    AbortRef.forget(ref)
    nil
  end

  defp agent_tool_to_ai_tool(%Tool{} = t) do
    %OctoPi.AI.Tool{
      name: t.name,
      description: t.description,
      parameters: t.parameters
    }
  end

  # Normalize an incoming message: strings become User messages,
  # existing message structs pass through.
  defp normalize(str) when is_binary(str) do
    %User{content: str, timestamp: :os.system_time(:millisecond)}
  end

  defp normalize(msgs) when is_list(msgs), do: Enum.map(msgs, &normalize/1)

  defp normalize(%User{} = m), do: m
  defp normalize(%{__struct__: _} = m), do: m
end
