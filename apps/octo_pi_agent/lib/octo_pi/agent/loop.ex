defmodule OctoPi.Agent.Loop do
  @moduledoc """
  Per-loop GenServer owning the transcript, queues, tools,
  subscribers, and turn iteration. Called via the `OctoPi.Agent`
  facade; no one should import this module directly.

  Drives the run via the `OctoPi.Agent.Turn` FSM. Each turn:
  Loop feeds an event into `Turn.handle_event/2`, walks the
  returned action list, and executes each action — spawning the
  stream Task, the tool-batch Task, dispatching subscriber events,
  appending the assistant + tool results, and deciding whether to
  spawn the next turn or end the run.

  Stream and tool-batch Tasks `send/2` ref-tagged messages back to
  Loop: `{:agent_event, ref, event}`, `{:stream_done, ref,
  assistant}`, `{:stream_failed, ref, reason}`, `{:tool_batch_done,
  ref, results}`. Loop's `handle_info` ref-gates against
  `state.loop.turn_ref` — messages from a killed Task are
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
  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Transport
  alias OctoPi.Agent.Turn
  alias OctoPi.Agent.Turn.Worker
  alias OctoPi.Agent.TurnTaskSupervisor
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model

  @type mode :: :sync | :async

  # The only externally-visible function on this module is `start_link/1`,
  # consumed by callers via `OctoPi.Agent.start_loop/1`. All other
  # operations are GenServer messages — invoked through the front-facing
  # `OctoPi.Agent` API, never against this module directly.
  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # ---------- GenServer callbacks ----------

  @impl true
  def init(opts) do
    state =
      %Loop.State{
        model: Keyword.fetch!(opts, :model),
        system_prompt: Keyword.get(opts, :system_prompt),
        tools: Keyword.get(opts, :tools, []),
        thinking_level: Keyword.get(opts, :thinking_level, :off),
        transport: Keyword.get(opts, :transport, Transport.Direct),
        before_tool_call: Keyword.get(opts, :before_tool_call),
        after_tool_call: Keyword.get(opts, :after_tool_call),
        convert_to_llm: Keyword.fetch!(opts, :convert_to_llm),
        messages: Keyword.get(opts, :messages, []),
        auto_compact_reserve_tokens: Keyword.get(opts, :auto_compact_reserve_tokens),
        turn: Turn.new()
      }
      |> maybe_override_queue(:steering_queue, opts[:steering_queue_bound])
      |> maybe_override_queue(:follow_up_queue, opts[:follow_up_queue_bound])

    {:ok,
     %{
       loop: state,
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
    if store.loop.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      loop = %{store.loop | messages: store.loop.messages ++ msgs}
      {:reply, :ok, %{store | loop: loop}, {:continue, :start_run}}
    end
  end

  def handle_call(:continue, _from, store) do
    if store.loop.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      {:reply, :ok, store, {:continue, :start_run}}
    end
  end

  def handle_call({:steer, msg}, _from, store) do
    case PendingMessageQueue.enqueue(store.loop.steering_queue, msg) do
      {:ok, q} -> {:reply, :ok, put_in(store.loop.steering_queue, q)}
      {:error, :full} = err -> {:reply, err, store}
    end
  end

  def handle_call({:follow_up, msg}, _from, store) do
    case PendingMessageQueue.enqueue(store.loop.follow_up_queue, msg) do
      {:ok, q} -> {:reply, :ok, put_in(store.loop.follow_up_queue, q)}
      {:error, :full} = err -> {:reply, err, store}
    end
  end

  def handle_call({:set_queue_mode, :steering, mode}, _from, store),
    do: {:reply, :ok, put_in(store.loop.steering_queue.mode, mode)}

  def handle_call({:set_queue_mode, :follow_up, mode}, _from, store),
    do: {:reply, :ok, put_in(store.loop.follow_up_queue.mode, mode)}

  def handle_call({:set_thinking_level, level}, _from, store),
    do: {:reply, :ok, put_in(store.loop.thinking_level, level)}

  def handle_call({:set_model, model}, _from, store), do: {:reply, :ok, put_in(store.loop.model, model)}

  def handle_call({:push_message, msg}, _from, store),
    do: {:reply, :ok, put_in(store.loop.messages, store.loop.messages ++ [msg])}

  def handle_call({:set_messages, msgs}, _from, store), do: {:reply, :ok, put_in(store.loop.messages, msgs)}

  def handle_call({:set_auto_compact_reserve_tokens, reserve}, _from, store),
    do: {:reply, :ok, put_in(store.loop.auto_compact_reserve_tokens, reserve)}

  def handle_call({:add_tool, tool}, _from, store) do
    tools = store.loop.tools
    new_tools = if Enum.any?(tools, &(&1.name == tool.name)), do: tools, else: tools ++ [tool]
    {:reply, :ok, put_in(store.loop.tools, new_tools)}
  end

  def handle_call(:drain_steering, _from, store) do
    {msgs, q} = PendingMessageQueue.drain(store.loop.steering_queue)
    {:reply, msgs, put_in(store.loop.steering_queue, q)}
  end

  def handle_call(:drain_follow_up, _from, store) do
    {msgs, q} = PendingMessageQueue.drain(store.loop.follow_up_queue)
    {:reply, msgs, put_in(store.loop.follow_up_queue, q)}
  end

  def handle_call(:abort, _from, store) do
    if store.loop.is_streaming? do
      # 1. Flip ETS abort flag (cooperative backstop for tools).
      # 2. Brutal-kill the active Task (stream or tool-batch).
      # 3. Feed :abort_requested into Turn — emits :cancel_active_task
      #    (already done) and transitions to :cancelling.
      # 4. Clear turn_ref so any in-flight {:agent_event, ref, _}
      #    from the dying Task fails the ref-gate.
      # 5. Synthesize aborted assistant + AgentEnd, end the run.
      if store.loop.abort_ref, do: AbortRef.abort(store.loop.abort_ref)

      if is_pid(store.loop.turn_pid) and Process.alive?(store.loop.turn_pid) do
        Process.exit(store.loop.turn_pid, :kill)
      end

      store =
        store
        |> put_in([Access.key(:loop), Access.key(:turn_pid)], nil)
        |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)

      {:reply, :ok, end_run_aborted(store, :killed)}
    else
      {:reply, :ok, store}
    end
  end

  # F3: fire-and-forget compact — returns :ok immediately. Completion
  # is observable via %Event.CompactionEnd{} on the subscriber stream;
  # callers who need to synchronize use wait_for_idle/2.
  def handle_call({:compact, _opts}, _from, %{loop: %{is_streaming?: true}} = store) do
    {:reply, {:error, :busy}, store}
  end

  def handle_call({:compact, opts}, _from, store) do
    store = put_in(store.loop.is_streaming?, true)
    store = advance(store, {:compact_requested, opts})
    {:reply, :ok, store}
  end

  # F3/F4: response from a CompactionRequested subscriber. Ref-gates
  # against the active turn_ref — late or stale responses get
  # {:error, :stale} and don't perturb Turn state.
  def handle_call({:compaction_response, ref, result}, _from, store) do
    if ref == store.loop.turn_ref do
      store = advance(store, {:compaction_response, result})
      {:reply, :ok, after_compaction(store, result)}
    else
      {:reply, {:error, :stale}, store}
    end
  end

  def handle_call(:state, _from, store), do: {:reply, store.loop, store}

  def handle_call(:wait_for_idle, from, store) do
    if store.loop.is_streaming? do
      {:noreply, %{store | idle_waiters: [from | store.idle_waiters]}}
    else
      {:reply, :ok, store}
    end
  end

  # ---------- handle_continue ----------

  @impl true
  def handle_continue(:start_run, store) do
    {:noreply, start_run(store)}
  end

  # ---------- handle_info: Task → Loop messages ----------

  @impl true

  # Subscriber-facing event from a stream/tool-batch Task. Forward
  # only when the ref matches the *current* turn_ref; events from a
  # killed/cancelled Task are dropped.
  def handle_info({:agent_event, ref, event}, store) do
    if ref == store.loop.turn_ref do
      Subscribers.dispatch(self(), event)
    end

    {:noreply, store}
  end

  # Stream Task finished cleanly. Feed `:stream_done` into Turn and
  # execute the resulting actions (start_tool_batch or turn_done).
  def handle_info({:stream_done, ref, %Assistant{} = assistant}, store) do
    if ref == store.loop.turn_ref do
      {:noreply, advance(store, {:stream_done, assistant})}
    else
      {:noreply, store}
    end
  end

  def handle_info({:stream_failed, ref, reason}, store) do
    if ref == store.loop.turn_ref do
      {:noreply, advance(store, {:stream_failed, reason})}
    else
      {:noreply, store}
    end
  end

  def handle_info({:tool_batch_done, ref, results}, store) do
    if ref == store.loop.turn_ref do
      {:noreply, advance(store, {:tool_batch_done, results})}
    else
      {:noreply, store}
    end
  end

  # Task crashed (rescue caught most things; this is a defensive
  # backstop). If the dying pid matches turn_pid, treat as a stream
  # failure.
  def handle_info({:DOWN, _mref, :process, pid, reason}, store) do
    if pid == store.loop.turn_pid and reason != :normal do
      store =
        store
        |> put_in([Access.key(:loop), Access.key(:turn_pid)], nil)
        |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)

      {:noreply, end_run_aborted(store, reason)}
    else
      {:noreply, store}
    end
  end

  def handle_info(_msg, store), do: {:noreply, store}

  # ---------- run / turn lifecycle ----------

  defp start_run(store) do
    abort_ref = AbortRef.new()
    session_id = Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)

    :telemetry.execute(
      [:octo_pi_agent, :loop, :start],
      %{system_time: System.system_time()},
      %{model: store.loop.model.id, session_id: session_id}
    )

    Subscribers.dispatch(self(), %Event.AgentStart{})

    loop = %{
      store.loop
      | is_streaming?: true,
        error_message: nil,
        abort_ref: abort_ref,
        run_started_at_mono: System.monotonic_time(),
        session_id: session_id,
        turn: Turn.new(),
        compaction_overflow_attempted?: false
    }

    advance(%{store | loop: loop, turn_id: 0}, :prompt_received)
  end

  # Feed an event into Turn, then execute the returned action list
  # against `store`. May recursively re-enter (e.g. `:turn_done`
  # action triggers a fresh `:prompt_received` for the next turn).
  defp advance(store, event) do
    {turn, actions} = Turn.handle_event(store.loop.turn, event)
    store = put_in(store.loop.turn, turn)
    execute_actions(store, actions)
  end

  defp execute_actions(store, actions), do: Enum.reduce(actions, store, &execute_action/2)

  # `{:emit_event, ...}` — subscriber dispatch + per-turn telemetry hooks.
  defp execute_action({:emit_event, %Event.TurnStart{turn: t} = ev}, store) do
    Subscribers.dispatch(self(), ev)

    :telemetry.execute(
      [:octo_pi_agent, :turn, :start],
      %{system_time: System.system_time()},
      %{turn: t, session_id: store.loop.session_id}
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
    ctx = build_turn_context(store.loop)
    loop = store.loop

    {:ok, pid} =
      Task.Supervisor.start_child(
        TurnTaskSupervisor,
        fn ->
          Worker.stream(parent, ref, %{
            context: ctx,
            model: loop.model,
            transport: loop.transport
          })
        end,
        restart: :temporary
      )

    Process.monitor(pid)

    store
    |> put_in([Access.key(:loop), Access.key(:turn_pid)], pid)
    |> put_in([Access.key(:loop), Access.key(:turn_ref)], ref)
  end

  # `{:start_tool_batch, calls}` — spawn the tool-batch Task; mode
  # resolved here from tool defs (Turn doesn't carry them).
  defp execute_action({:start_tool_batch, calls}, store) do
    ref = make_ref()
    parent = self()
    loop = store.loop
    mode = Worker.resolve_mode(calls, loop.tools)

    opts = %{
      abort_ref: loop.abort_ref,
      tools: loop.tools,
      mode: mode,
      before_tool_call: loop.before_tool_call,
      after_tool_call: loop.after_tool_call,
      session_id: loop.session_id
    }

    {:ok, pid} =
      Task.Supervisor.start_child(
        TurnTaskSupervisor,
        fn -> Worker.tool_batch(parent, ref, opts, calls) end,
        restart: :temporary
      )

    Process.monitor(pid)

    store
    |> put_in([Access.key(:loop), Access.key(:turn_pid)], pid)
    |> put_in([Access.key(:loop), Access.key(:turn_ref)], ref)
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
    |> put_in([Access.key(:loop), Access.key(:turn_pid)], nil)
    |> put_in([Access.key(:loop), Access.key(:turn_ref)], ref)
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
    assistant = synth_assistant(store.loop.model, reason, error_message)
    finish_turn(store, assistant, [], reason)
  end

  defp finish_turn(store, %Assistant{} = assistant, tool_results, reason) do
    emit_turn_stop(store, reason)

    messages = store.loop.messages ++ [assistant | tool_results]

    store =
      store
      |> put_in([Access.key(:loop), Access.key(:messages)], messages)
      |> put_in([Access.key(:loop), Access.key(:turn_pid)], nil)
      |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)

    case decide_next(reason, store) do
      {:continue, store} ->
        if over_threshold?(assistant, store) do
          store = put_in(store.loop.compaction_auto?, :continue)
          advance(store, {:compact_requested, [auto?: true]})
        else
          {turn, actions} = Turn.handle_event(store.loop.turn, :prompt_received)
          store = put_in(store.loop.turn, turn)
          execute_actions(store, actions)
        end

      {:terminate, store} ->
        cond do
          # Overflow: context too long for the model — compact and retry.
          # On second overflow in the same run, emit error and end.
          overflow_error?(assistant, store) and store.loop.compaction_overflow_attempted? ->
            Subscribers.dispatch(self(), %Event.CompactionEnd{
              result: {:error, :overflow_recovery_failed}
            })

            end_run(store, :error)

          overflow_error?(assistant, store) ->
            store =
              store
              |> put_in([Access.key(:loop), Access.key(:compaction_overflow_attempted?)], true)
              |> put_in([Access.key(:loop), Access.key(:compaction_auto?)], :overflow_retry)
              # Remove the overflow error message from the transcript — it's
              # saved to conversation history by the Coder, but mustn't appear in
              # the LLM context on retry.
              |> put_in(
                [Access.key(:loop), Access.key(:messages)],
                Enum.drop(store.loop.messages, -1)
              )

            advance(store, {:compact_requested, [auto?: true]})

          # Non-overflow error with high estimated context: compact, then end run.
          # Uses last successful assistant's token count as the estimate when
          # the current error message carries zero usage data.
          over_threshold_on_error?(assistant, store) ->
            store = put_in(store.loop.compaction_auto?, :end_after)
            advance(store, {:compact_requested, [auto?: true]})

          true ->
            end_run(store, reason)
        end
    end
  end

  # Decide whether to continue or terminate after a turn.
  defp decide_next(reason, store) when reason in [:error, :aborted], do: {:terminate, store}

  defp decide_next(:tool_use, store) do
    {steers, q} = PendingMessageQueue.drain(store.loop.steering_queue)

    store =
      store
      |> put_in([Access.key(:loop), Access.key(:steering_queue)], q)
      |> put_in(
        [Access.key(:loop), Access.key(:messages)],
        store.loop.messages ++ steers
      )

    {:continue, store}
  end

  defp decide_next(_terminal_reason, store) do
    {followups, q} = PendingMessageQueue.drain(store.loop.follow_up_queue)

    case followups do
      [] ->
        {:terminate, store}

      msgs ->
        store =
          store
          |> put_in([Access.key(:loop), Access.key(:follow_up_queue)], q)
          |> put_in(
            [Access.key(:loop), Access.key(:messages)],
            store.loop.messages ++ msgs
          )

        {:continue, store}
    end
  end

  # Per-turn LLM context. `convert_to_llm` is a stateless transform
  # `([AgentMessage] -> [Message])` applied to the transcript at
  # call time. Coder installs `to_llm/1` to flatten synthetic
  # message types; standalone Agent users pass `&Function.identity/1`.
  defp build_turn_context(loop) do
    %AIContext{
      system_prompt: loop.system_prompt,
      messages: loop.convert_to_llm.(loop.messages),
      tools: Enum.map(loop.tools, &agent_tool_to_ai_tool/1)
    }
  end

  defp end_run(store, reason) do
    Subscribers.dispatch(self(), %Event.AgentEnd{
      reason: reason,
      messages: store.loop.messages
    })

    emit_loop_stop(store.loop, reason, store.turn_id, length(store.loop.messages))
    flip_idle(store)
  end

  defp end_run_aborted(store, :normal) do
    # Task exited :normal without a completion message — shouldn't
    # happen in practice. Be defensive: just flip idle.
    flip_idle(store)
  end

  defp end_run_aborted(store, _reason) do
    messages = store.loop.messages ++ [aborted_assistant(store.loop.model)]

    Subscribers.dispatch(self(), %Event.AgentEnd{
      reason: :aborted,
      messages: messages
    })

    emit_loop_stop(store.loop, :aborted, store.turn_id, length(messages))

    store = put_in(store.loop.messages, messages)
    store = put_in(store.loop.error_message, "aborted by caller")
    flip_idle(store)
  end

  # F3: manual compaction — update last_compaction_at_ms on success, then flip idle.
  defp after_compaction(%{loop: %{compaction_auto?: false}} = store, {:ok, _}) do
    store = put_in(store.loop.last_compaction_at_ms, System.system_time(:millisecond))
    flip_compaction_idle(store)
  end

  defp after_compaction(%{loop: %{compaction_auto?: false}} = store, _failure) do
    flip_compaction_idle(store)
  end

  # F4/:continue — drain any messages that arrived during compaction, then resume run.
  defp after_compaction(%{loop: %{compaction_auto?: :continue}} = store, {:ok, _}) do
    store = drain_queues_into_transcript(store)

    store =
      store
      |> put_in([Access.key(:loop), Access.key(:compaction_auto?)], false)
      |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)
      |> put_in([Access.key(:loop), Access.key(:last_compaction_at_ms)], System.system_time(:millisecond))

    advance(store, :prompt_received)
  end

  # F5/:overflow_retry — error message was already popped; resume run to retry.
  defp after_compaction(%{loop: %{compaction_auto?: :overflow_retry}} = store, {:ok, _}) do
    store = drain_queues_into_transcript(store)

    store =
      store
      |> put_in([Access.key(:loop), Access.key(:compaction_auto?)], false)
      |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)
      |> put_in([Access.key(:loop), Access.key(:last_compaction_at_ms)], System.system_time(:millisecond))

    advance(store, :prompt_received)
  end

  # F5/:end_after — compact was triggered by a high-context error; end the run after.
  defp after_compaction(%{loop: %{compaction_auto?: :end_after}} = store, {:ok, _}) do
    store =
      store
      |> put_in([Access.key(:loop), Access.key(:compaction_auto?)], false)
      |> put_in([Access.key(:loop), Access.key(:turn_ref)], nil)
      |> put_in([Access.key(:loop), Access.key(:last_compaction_at_ms)], System.system_time(:millisecond))

    end_run(store, :error)
  end

  # Any auto-compact failure or cancel — clear flag, end the run.
  defp after_compaction(store, _failure) do
    store = put_in(store.loop.compaction_auto?, false)
    end_run(store, :error)
  end

  # Drain steering + follow-up queues into the transcript. Used when resuming
  # after auto-compact to pick up messages enqueued during the compaction window.
  defp drain_queues_into_transcript(store) do
    {steers, sq} = PendingMessageQueue.drain(store.loop.steering_queue)
    {followups, fq} = PendingMessageQueue.drain(store.loop.follow_up_queue)

    store
    |> put_in([Access.key(:loop), Access.key(:steering_queue)], sq)
    |> put_in([Access.key(:loop), Access.key(:follow_up_queue)], fq)
    |> put_in(
      [Access.key(:loop), Access.key(:messages)],
      store.loop.messages ++ steers ++ followups
    )
  end

  # F4: returns true when this assistant's context tokens plus the configured
  # reserve exceed the model context window.  Used on the :continue path.
  defp over_threshold?(%Assistant{usage: usage}, %{loop: loop}) do
    reserve = loop.auto_compact_reserve_tokens
    ctx = loop.model && loop.model.context_window
    tokens = context_tokens_from_usage(usage)

    is_integer(reserve) and is_integer(ctx) and is_integer(tokens) and
      tokens + reserve > ctx
  end

  # Mirrors upstream `calculateContextTokens`: prefer provider-supplied
  # `total_tokens` when positive; otherwise sum input + output + cache_read +
  # cache_write so prompt-cache reads (common with Anthropic caching) still
  # count toward the trigger.
  defp context_tokens_from_usage(%{total_tokens: t}) when is_integer(t) and t > 0, do: t

  defp context_tokens_from_usage(%{input: i, output: o, cache_read: cr, cache_write: cw})
       when is_integer(i) and is_integer(o) and is_integer(cr) and is_integer(cw) do
    i + o + cr + cw
  end

  defp context_tokens_from_usage(_), do: nil

  # F5: returns true when the current assistant is an error (with no useful
  # usage) but a prior successful assistant in the transcript is over the
  # threshold.  Used on the :terminate/:error path so persistent API errors
  # (e.g. 529 overloaded) can still trigger compaction.
  defp over_threshold_on_error?(%Assistant{stop_reason: :error}, %{loop: loop}) do
    reserve = loop.auto_compact_reserve_tokens
    ctx = loop.model && loop.model.context_window

    with r when is_integer(r) <- reserve,
         c when is_integer(c) <- ctx,
         tokens when is_integer(tokens) <-
           find_last_successful_context_tokens(loop.messages, loop.last_compaction_at_ms) do
      tokens + r > c
    else
      _ -> false
    end
  end

  defp over_threshold_on_error?(_assistant, _store), do: false

  # Walk newest-to-oldest through the message log and return the context-token
  # count of the first successful (non-error, non-aborted) assistant with a
  # positive token total that is NOT stale (i.e. its timestamp is after the
  # last compaction).  Returns nil when nothing qualifies.
  defp find_last_successful_context_tokens(messages, last_compaction_at_ms) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Assistant{stop_reason: stop, usage: usage, timestamp: ts}
      when stop not in [:error, :aborted] ->
        tokens = context_tokens_from_usage(usage)

        if is_integer(tokens) and tokens > 0 and
             (is_nil(last_compaction_at_ms) or is_nil(ts) or ts > last_compaction_at_ms) do
          tokens
        end

      _ ->
        nil
    end)
  end

  # F5: returns true when the assistant's stop reason is :error with a message
  # that matches a known context-overflow pattern, the message is from the
  # current model, and the message is not stale (i.e. it arrived after the
  # last compaction boundary, if any).
  defp overflow_error?(%Assistant{stop_reason: :error, error_message: msg, model: model_id, timestamp: ts}, %{
         loop: loop
       })
       when is_binary(msg) do
    same_model = loop.model != nil and loop.model.id == model_id
    not_stale = is_nil(loop.last_compaction_at_ms) or ts > loop.last_compaction_at_ms
    same_model and not_stale and context_overflow_msg?(msg)
  end

  defp overflow_error?(_assistant, _store), do: false

  @overflow_patterns [
    ~r/prompt is too long/i,
    ~r/request_too_large/i,
    ~r/exceeds the context window/i,
    ~r/input token count.*exceeds the maximum/i,
    ~r/maximum prompt length is \d+/i,
    ~r/reduce the length of the messages/i,
    ~r/maximum context length is \d+ tokens/i,
    ~r/exceeds the limit of \d+/i,
    ~r/exceeds the available context size/i,
    ~r/greater than the context length/i,
    ~r/context window exceeds limit/i,
    ~r/exceeded model token limit/i,
    ~r/too large for model with \d+ maximum context length/i,
    ~r/context[_ ]length[_ ]exceeded/i,
    ~r/too many tokens/i,
    ~r/token limit exceeded/i
  ]

  @non_overflow_patterns [
    ~r/^(Throttling error|Service unavailable):/i,
    ~r/rate limit/i,
    ~r/too many requests/i
  ]

  defp context_overflow_msg?(msg) do
    not Enum.any?(@non_overflow_patterns, &Regex.match?(&1, msg)) and
      Enum.any?(@overflow_patterns, &Regex.match?(&1, msg))
  end

  # F3: lighter-weight idle flip for compaction. Doesn't touch
  # abort_ref, run_started_at_mono, or turn_id (those are run-scoped,
  # and compaction isn't a run).
  defp flip_compaction_idle(store) do
    loop = %{
      store.loop
      | is_streaming?: false,
        turn_pid: nil,
        turn_ref: nil,
        turn: Turn.new()
    }

    store = %{store | loop: loop}

    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  defp flip_idle(store) do
    loop = %{
      store.loop
      | is_streaming?: false,
        abort_ref: maybe_forget_ref(store.loop.abort_ref),
        turn_pid: nil,
        turn_ref: nil,
        run_started_at_mono: nil,
        turn: Turn.new(),
        compaction_overflow_attempted?: false
    }

    store = %{store | loop: loop, turn_id: 0, turn_started_at_mono: nil}

    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  @doc false
  @spec aborted_assistant(Model.t() | nil) :: Assistant.t()
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

  defp synth_assistant(%Model{} = model, stop_reason, error_message) do
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

  defp emit_loop_stop(%Loop.State{run_started_at_mono: nil}, _reason, _turn_count, _message_count), do: :ok

  defp emit_loop_stop(%Loop.State{} = state, reason, turn_count, message_count) do
    :telemetry.execute(
      [:octo_pi_agent, :loop, :stop],
      %{duration: System.monotonic_time() - state.run_started_at_mono},
      %{reason: reason, turn_count: turn_count, message_count: message_count, session_id: state.session_id}
    )
  end

  defp emit_turn_stop(%{turn_started_at_mono: nil}, _reason), do: :ok

  defp emit_turn_stop(%{turn_id: turn_id, turn_started_at_mono: started, loop: %{session_id: session_id}}, reason) do
    :telemetry.execute(
      [:octo_pi_agent, :turn, :stop],
      %{duration: System.monotonic_time() - started},
      %{turn: turn_id, stop_reason: reason, session_id: session_id}
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
end
