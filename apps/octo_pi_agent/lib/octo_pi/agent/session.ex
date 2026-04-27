defmodule OctoPi.Agent.Session do
  @moduledoc """
  Per-session GenServer owning the transcript, queues, tools,
  subscribers, and turn iteration. Called via the `OctoPi.Agent`
  facade; no one should import this module directly.

  Drives the run via the `OctoPi.Agent.Turn` FSM. Each turn:
  Session feeds an event into `Turn.handle_event/2`, walks the
  returned action list, and executes each action — spawning the
  stream Task, the tool-batch Task, dispatching subscriber events,
  appending the assistant + tool results, and deciding whether to
  spawn the next turn or end the run.

  Stream and tool-batch Tasks `send/2` ref-tagged messages back to
  Session: `{:agent_event, ref, event}`, `{:stream_done, ref,
  assistant}`, `{:stream_failed, ref, reason}`, `{:tool_batch_done,
  ref, results}`. Session's `handle_info` ref-gates against
  `state.session.turn_ref` — messages from a killed Task are
  silently dropped.

  State invariants:
    - `is_streaming?` is `true` iff a run is in flight.
    - `turn_pid` is the pid of the *current Task* (stream or
      tool-batch), or nil.
    - `turn_ref` is the ref tagging messages from that Task, or nil.
    - `abort_ref` is the current run's `AbortRef`, or nil.
  """

  use GenServer

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.MessageLog
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Transport
  alias OctoPi.Agent.Turn
  alias OctoPi.Agent.Turn.Worker
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User

  @type mode :: :sync | :async

  # ---------- public API ----------

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc false
  def prompt(pid, msg_or_msgs),
    do: GenServer.call(pid, {:prompt, List.wrap(normalize(msg_or_msgs))})

  @doc false
  def continue(pid), do: GenServer.call(pid, :continue)

  @doc false
  def steer(pid, msg), do: GenServer.call(pid, {:steer, normalize(msg)})

  @doc false
  def follow_up(pid, msg), do: GenServer.call(pid, {:follow_up, normalize(msg)})

  @doc false
  def set_queue_mode(pid, queue, mode)
      when queue in [:steering, :follow_up] and mode in [:one_at_a_time, :all],
      do: GenServer.call(pid, {:set_queue_mode, queue, mode})

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
  def compact(pid, opts \\ []), do: GenServer.call(pid, {:compact, opts}, :infinity)

  @doc false
  def compaction_response(pid, ref, result),
    do: GenServer.call(pid, {:compaction_response, ref, result})

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
        messages: MessageLog.new(Keyword.get(opts, :messages, [])),
        turn: Turn.new()
      }
      |> maybe_override_queue(:steering_queue, opts[:steering_queue_bound])
      |> maybe_override_queue(:follow_up_queue, opts[:follow_up_queue_bound])

    {:ok,
     %{
       session: state,
       idle_waiters: [],
       turn_id: 0,
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
      # 1. Flip ETS abort flag (cooperative backstop for tools).
      # 2. Brutal-kill the active Task (stream or tool-batch).
      # 3. Feed :abort_requested into Turn — emits :cancel_active_task
      #    (already done) and transitions to :cancelling.
      # 4. Clear turn_ref so any in-flight {:agent_event, ref, _}
      #    from the dying Task fails the ref-gate.
      # 5. Synthesize aborted assistant + AgentEnd, end the run.
      if store.session.abort_ref, do: AbortRef.abort(store.session.abort_ref)

      if is_pid(store.session.turn_pid) and Process.alive?(store.session.turn_pid) do
        Process.exit(store.session.turn_pid, :kill)
      end

      store =
        store
        |> put_in([Access.key(:session), Access.key(:turn_pid)], nil)
        |> put_in([Access.key(:session), Access.key(:turn_ref)], nil)

      {:reply, :ok, end_run_aborted(store, :killed)}
    else
      {:reply, :ok, store}
    end
  end

  # F3: synchronous manual compact. Caller blocks until either the
  # Subscriber-supplied `compaction_response/3` arrives, an abort
  # interrupts, or the GenServer.call hits :infinity (it never does
  # — caller is expected to time out if needed via Task.async).
  def handle_call({:compact, _opts}, _from, %{session: %{is_streaming?: true}} = store) do
    {:reply, {:error, :busy}, store}
  end

  def handle_call({:compact, opts}, from, store) do
    # Mark the session busy *before* feeding Turn so re-entrant
    # handle_calls (e.g. an immediate :prompt while compact is in
    # flight) see is_streaming? = true.
    store = put_in(store.session.is_streaming?, true)
    store = advance(store, {:compact_requested, from, opts})
    {:noreply, store}
  end

  # F3: synchronous response from a CompactionRequested subscriber.
  # Ref-gates against the active turn_ref — late or stale responses
  # get a {:error, :stale} reply and don't perturb Turn state.
  def handle_call({:compaction_response, ref, result}, _from, store) do
    if ref == store.session.turn_ref do
      store = advance(store, {:compaction_response, result})
      # Compaction's `:reply_to` action already replied to the
      # original `compact/1` caller; flip back to idle here so
      # subsequent prompts/compacts can proceed.
      {:reply, :ok, flip_compaction_idle(store)}
    else
      {:reply, {:error, :stale}, store}
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

  # ---------- handle_info: Task → Session messages ----------

  @impl true

  # Subscriber-facing event from a stream/tool-batch Task. Forward
  # only when the ref matches the *current* turn_ref; events from a
  # killed/cancelled Task are dropped.
  def handle_info({:agent_event, ref, event}, store) do
    if ref == store.session.turn_ref do
      Subscribers.dispatch(self(), event)
    end

    {:noreply, store}
  end

  # Stream Task finished cleanly. Feed `:stream_done` into Turn and
  # execute the resulting actions (start_tool_batch or turn_done).
  def handle_info({:stream_done, ref, %Assistant{} = assistant}, store) do
    if ref == store.session.turn_ref do
      {:noreply, advance(store, {:stream_done, assistant})}
    else
      {:noreply, store}
    end
  end

  def handle_info({:stream_failed, ref, reason}, store) do
    if ref == store.session.turn_ref do
      {:noreply, advance(store, {:stream_failed, reason})}
    else
      {:noreply, store}
    end
  end

  def handle_info({:tool_batch_done, ref, results}, store) do
    if ref == store.session.turn_ref do
      {:noreply, advance(store, {:tool_batch_done, results})}
    else
      {:noreply, store}
    end
  end

  # Task crashed (rescue caught most things; this is a defensive
  # backstop). If the dying pid matches turn_pid, treat as a stream
  # failure.
  def handle_info({:DOWN, _mref, :process, pid, reason}, store) do
    cond do
      pid == store.session.turn_pid and reason != :normal ->
        store =
          store
          |> put_in([Access.key(:session), Access.key(:turn_pid)], nil)
          |> put_in([Access.key(:session), Access.key(:turn_ref)], nil)

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
        run_started_at_mono: System.monotonic_time(),
        turn: Turn.new()
    }

    advance(%{store | session: session, turn_id: 0}, :prompt_received)
  end

  # Feed an event into Turn, then execute the returned action list
  # against `store`. May recursively re-enter (e.g. `:turn_done`
  # action triggers a fresh `:prompt_received` for the next turn).
  defp advance(store, event) do
    {turn, actions} = Turn.handle_event(store.session.turn, event)
    store = put_in(store.session.turn, turn)
    execute_actions(store, actions)
  end

  defp execute_actions(store, actions), do: Enum.reduce(actions, store, &execute_action/2)

  # `{:emit_event, ...}` — subscriber dispatch + per-turn telemetry hooks.
  defp execute_action({:emit_event, %Event.TurnStart{turn: t} = ev}, store) do
    Subscribers.dispatch(self(), ev)

    :telemetry.execute(
      [:octo_pi_agent, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: t}
    )

    %{store | turn_id: t, turn_started_at_mono: System.monotonic_time()}
  end

  defp execute_action({:emit_event, %Event.TurnEnd{} = ev}, store) do
    Subscribers.dispatch(self(), ev)
    store
  end

  defp execute_action({:emit_event, ev}, store) do
    Subscribers.dispatch(self(), ev)
    store
  end

  # `:start_stream` — spawn the stream Task with a fresh ref.
  defp execute_action(:start_stream, store) do
    ref = make_ref()
    parent = self()
    ctx = build_turn_context(store.session)
    session = store.session

    {:ok, pid} =
      Task.Supervisor.start_child(
        OctoPi.Agent.TurnTaskSupervisor,
        fn ->
          Worker.stream(parent, ref, %{
            context: ctx,
            model: session.model,
            transport: session.transport
          })
        end,
        restart: :temporary
      )

    Process.monitor(pid)

    store
    |> put_in([Access.key(:session), Access.key(:turn_pid)], pid)
    |> put_in([Access.key(:session), Access.key(:turn_ref)], ref)
  end

  # `{:start_tool_batch, calls}` — spawn the tool-batch Task; mode
  # resolved here from tool defs (Turn doesn't carry them).
  defp execute_action({:start_tool_batch, calls}, store) do
    ref = make_ref()
    parent = self()
    session = store.session
    mode = Worker.resolve_mode(calls, session.tools)

    opts = %{
      abort_ref: session.abort_ref,
      tools: session.tools,
      mode: mode,
      before_tool_call: session.before_tool_call,
      after_tool_call: session.after_tool_call
    }

    {:ok, pid} =
      Task.Supervisor.start_child(
        OctoPi.Agent.TurnTaskSupervisor,
        fn -> Worker.tool_batch(parent, ref, opts, calls) end,
        restart: :temporary
      )

    Process.monitor(pid)

    store
    |> put_in([Access.key(:session), Access.key(:turn_pid)], pid)
    |> put_in([Access.key(:session), Access.key(:turn_ref)], ref)
  end

  # `:cancel_active_task` — abort/1 already brutal-killed the pid;
  # this action is a no-op marker today (kept for explicitness in the
  # action trace).
  defp execute_action(:cancel_active_task, store), do: store

  # F3: emit CompactionRequested via Subscribers and stash a fresh
  # ref. There's no Task on Agent's side — the response arrives as
  # an external `compaction_response/3` GenServer.call.
  defp execute_action({:start_compaction, opts}, store) do
    ref = make_ref()
    Subscribers.dispatch(self(), %Event.CompactionRequested{ref: ref, opts: opts})

    store
    |> put_in([Access.key(:session), Access.key(:turn_pid)], nil)
    |> put_in([Access.key(:session), Access.key(:turn_ref)], ref)
  end

  # F3: reply to the original synchronous caller (e.g. `compact/1`).
  defp execute_action({:reply_to, from, term}, store) do
    GenServer.reply(from, term)
    store
  end

  # `{:turn_done, assistant, tool_results, reason}` — append to
  # transcript, telemetry, decide next.
  defp execute_action({:turn_done, %Assistant{} = assistant, tool_results, reason}, store) do
    finish_turn(store, assistant, tool_results, reason)
  end

  # `{:turn_synth_done, reason, error_message}` — Turn couldn't
  # synthesize an Assistant.t() (no provider/model in pure data).
  # Build it here and proceed identically to :turn_done.
  defp execute_action({:turn_synth_done, reason, error_message}, store) do
    assistant = synth_assistant(store.session.model, reason, error_message)
    finish_turn(store, assistant, [], reason)
  end

  defp finish_turn(store, %Assistant{} = assistant, tool_results, reason) do
    emit_turn_stop(store, reason)

    messages =
      store.session.messages
      |> MessageLog.push(assistant)
      |> MessageLog.append_many(tool_results)

    store =
      store
      |> put_in([Access.key(:session), Access.key(:messages)], messages)
      |> put_in([Access.key(:session), Access.key(:turn_pid)], nil)
      |> put_in([Access.key(:session), Access.key(:turn_ref)], nil)

    case decide_next(reason, store) do
      {:continue, store} ->
        {turn, actions} = Turn.handle_event(store.session.turn, :prompt_received)
        store = put_in(store.session.turn, turn)
        execute_actions(store, actions)

      {:terminate, store} ->
        end_run(store, reason)
    end
  end

  # Decide whether to continue or terminate after a turn.
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
    # Task exited :normal without a completion message — shouldn't
    # happen in practice. Be defensive: just flip idle.
    flip_idle(store)
  end

  defp end_run_aborted(store, _reason) do
    messages = MessageLog.push(store.session.messages, aborted_assistant(store.session.model))

    Subscribers.dispatch(self(), %Event.AgentEnd{
      reason: :aborted,
      messages: MessageLog.to_list(messages)
    })

    emit_session_stop(store.session, :aborted, MessageLog.count(messages))

    store = put_in(store.session.messages, messages)
    store = put_in(store.session.error_message, "aborted by caller")
    flip_idle(store)
  end

  # F3: lighter-weight idle flip for compaction. Doesn't touch
  # abort_ref, run_started_at_mono, or turn_id (those are run-scoped,
  # and compaction isn't a run).
  defp flip_compaction_idle(store) do
    session = %{
      store.session
      | is_streaming?: false,
        turn_pid: nil,
        turn_ref: nil,
        turn: Turn.new()
    }

    store = %{store | session: session}

    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  defp flip_idle(store) do
    session = %{
      store.session
      | is_streaming?: false,
        abort_ref: maybe_forget_ref(store.session.abort_ref),
        turn_pid: nil,
        turn_ref: nil,
        run_started_at_mono: nil,
        turn: Turn.new()
    }

    store = %{store | session: session, turn_id: 0, turn_started_at_mono: nil}

    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  @doc false
  @spec aborted_assistant(OctoPi.AI.Model.t() | nil) :: Assistant.t()
  def aborted_assistant(model), do: synth_assistant(model, :aborted, "aborted by caller")

  defp synth_assistant(nil, stop_reason, error_message) do
    %Assistant{
      api: :octo_pi_agent,
      provider: :octo_pi_agent,
      model: "",
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: stop_reason,
      error_message: error_message
    }
  end

  defp synth_assistant(%OctoPi.AI.Model{} = model, stop_reason, error_message) do
    %Assistant{
      api: model.api,
      provider: model.provider,
      model: model.id,
      timestamp: :os.system_time(:millisecond),
      content: [],
      stop_reason: stop_reason,
      error_message: error_message
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

  defp emit_turn_stop(%{turn_id: turn_id, turn_started_at_mono: started}, reason) do
    :telemetry.execute(
      [:octo_pi_agent, :turn, :stop],
      %{duration: System.monotonic_time() - started},
      %{turn: turn_id, stop_reason: reason}
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

  defp normalize(str) when is_binary(str) do
    %User{content: str, timestamp: :os.system_time(:millisecond)}
  end

  defp normalize(msgs) when is_list(msgs), do: Enum.map(msgs, &normalize/1)

  defp normalize(%User{} = m), do: m
  defp normalize(%{__struct__: _} = m), do: m
end
