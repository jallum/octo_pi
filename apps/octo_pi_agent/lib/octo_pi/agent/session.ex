defmodule OctoPi.Agent.Session do
  @moduledoc """
  Per-session GenServer owning the transcript, tools, queues, and
  subscriber list. Called via the `OctoPi.Agent` facade; no one
  should import this module directly.

  This ticket (`octo-z1d.2`) lands the state machine — Idle →
  Running → Idle, with abort flipping Running → Aborting → Idle —
  plus the public API surface (prompt / continue / steer / follow_up
  / abort / subscribe / state / wait_for_idle). The actual LLM call
  + tool dispatch land in `octo-z1d.3`; for now prompt/continue
  stub out the run by immediately emitting `AgentStart` then
  `AgentEnd{reason: :stop}` without doing any work.

  State invariants:

    - `is_streaming?` is `true` iff a run is in flight.
    - `loop_task` is the Task.t of the running loop (nil when idle).
    - `abort_ref` is the current run's ref (nil when idle; set on
      run start and forgotten on run end).
    - Steering + follow-up enqueue works in any state; drainage only
      happens during a run (z1d.5 wires the drainage).
  """

  use GenServer

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.Message.Custom
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.Transport
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
  def set_queue_mode(pid, queue, mode)
      when queue in [:steering, :follow_up] and
             mode in [:one_at_a_time, :all] do
    GenServer.call(pid, {:set_queue_mode, queue, mode})
  end

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
    state = %Session.State{
      model: Keyword.fetch!(opts, :model),
      system_prompt: Keyword.get(opts, :system_prompt),
      tools: Keyword.get(opts, :tools, []),
      thinking_level: Keyword.get(opts, :thinking_level, :off),
      transport: Keyword.get(opts, :transport, Transport.Direct),
      before_tool_call: Keyword.get(opts, :before_tool_call),
      after_tool_call: Keyword.get(opts, :after_tool_call),
      messages: Keyword.get(opts, :messages, [])
    }

    {:ok, %{session: state, idle_waiters: []}}
  end

  @impl true
  def handle_call({:prompt, msgs}, _from, store) do
    if store.session.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      session = %{store.session | messages: store.session.messages ++ msgs}
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

  def handle_call({:set_queue_mode, :steering, mode}, _from, store) do
    {:reply, :ok, put_in(store.session.steering_queue.mode, mode)}
  end

  def handle_call({:set_queue_mode, :follow_up, mode}, _from, store) do
    {:reply, :ok, put_in(store.session.follow_up_queue.mode, mode)}
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
      # Flip the ETS flag (cooperative backstop) and brutal-kill the
      # loop task. Tool tasks started under `ToolSupervisor` are
      # linked to the loop, so they die with it. Cleanup (AgentEnd +
      # idle transition) happens in `handle_info({:DOWN, ...})`.
      if store.session.abort_ref, do: AbortRef.abort(store.session.abort_ref)
      if store.session.loop_task, do: Process.exit(store.session.loop_task, :kill)
    end

    {:reply, :ok, store}
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
  def handle_cast({:run_complete, messages, reason}, store) do
    emit_session_stop(store.session, reason, length(messages))

    session = %{
      store.session
      | messages: messages,
        abort_ref: maybe_forget_ref(store.session.abort_ref),
        loop_task: nil,
        run_started_at_mono: nil
    }

    {:noreply, idle(%{store | session: session})}
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, reason}, store) do
    if pid == store.session.loop_task do
      # Loop died. If the reason is :normal, the loop completed
      # cleanly and its `run_complete` cast will have already landed
      # (or will shortly) — nothing to synthesize. Otherwise (brutal
      # kill from abort, crash, etc.) synthesize an aborted assistant
      # message + AgentEnd so subscribers see a terminal event.
      {:noreply, on_loop_down(store, reason)}
    else
      {:noreply, store}
    end
  end

  def handle_info(_msg, store), do: {:noreply, store}

  # ---------- internal helpers ----------

  defp start_run(store) do
    abort_ref = AbortRef.new()
    session_pid = self()

    session_snapshot = %{
      store.session
      | is_streaming?: true,
        error_message: nil,
        abort_ref: abort_ref,
        run_started_at_mono: System.monotonic_time()
    }

    {:ok, pid} =
      Task.Supervisor.start_child(
        OctoPi.Agent.LoopSupervisor,
        fn ->
          Loop.run(%{
            session: session_pid,
            session_state: session_snapshot,
            abort_ref: abort_ref
          })
        end,
        restart: :temporary
      )

    Process.monitor(pid)
    %{store | session: %{session_snapshot | loop_task: pid}}
  end

  defp on_loop_down(store, :normal) do
    # Normal completion: run_complete handled (or will be) the
    # transcript update + session:stop emission. Just release the
    # abort ref + flip idle.
    session = %{
      store.session
      | abort_ref: maybe_forget_ref(store.session.abort_ref),
        loop_task: nil,
        run_started_at_mono: nil
    }

    idle(%{store | session: session})
  end

  defp on_loop_down(store, _reason) do
    messages = store.session.messages ++ [aborted_assistant()]

    Subscribers.dispatch(self(), %Event.AgentEnd{reason: :aborted, messages: messages})
    emit_session_stop(store.session, :aborted, length(messages))

    session = %{
      store.session
      | messages: messages,
        error_message: "aborted by caller",
        abort_ref: maybe_forget_ref(store.session.abort_ref),
        loop_task: nil,
        run_started_at_mono: nil
    }

    idle(%{store | session: session})
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
      %{session: self(), reason: reason, turn_count: turn_count}
    )
  end

  defp idle(store) do
    store = %{store | session: %{store.session | is_streaming?: false}}
    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  defp maybe_forget_ref(nil), do: nil

  defp maybe_forget_ref(ref) do
    AbortRef.forget(ref)
    nil
  end

  # Normalize an incoming message: strings become User messages,
  # existing message structs pass through.
  defp normalize(str) when is_binary(str) do
    %User{content: str, timestamp: :os.system_time(:millisecond)}
  end

  defp normalize(msgs) when is_list(msgs), do: Enum.map(msgs, &normalize/1)

  defp normalize(%User{} = m), do: m
  defp normalize(%Custom{} = m), do: m
  defp normalize(%{__struct__: _} = m), do: m
end
