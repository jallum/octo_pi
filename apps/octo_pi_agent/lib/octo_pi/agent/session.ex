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
  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.Message.Custom
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Transport
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
      # Cooperative: flip the ETS flag so the loop's between-turn
      # check bails out. Hard-kill via Task.shutdown lands in
      # octo-z1d.6.
      if store.session.abort_ref, do: AbortRef.abort(store.session.abort_ref)
      {:reply, :ok, store}
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
  def handle_cast({:run_complete, messages, _reason}, store) do
    session = %{
      store.session
      | messages: messages,
        abort_ref: maybe_forget_ref(store.session.abort_ref),
        loop_task: nil
    }

    {:noreply, idle(%{store | session: session})}
  end

  @impl true
  def handle_info({:DOWN, _mref, :process, pid, _reason}, store) do
    if pid == store.session.loop_task do
      # Loop died (crashed, brutal kill, or just completed without
      # having cast :run_complete yet). Release the abort ref +
      # flip idle.
      session = %{
        store.session
        | abort_ref: maybe_forget_ref(store.session.abort_ref),
          loop_task: nil
      }

      {:noreply, idle(%{store | session: session})}
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
        abort_ref: abort_ref
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
