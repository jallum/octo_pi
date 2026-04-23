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

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Message.Custom
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Subscribers
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
      {:reply, :ok, stub_run(%{store | session: session})}
    end
  end

  def handle_call(:continue, _from, store) do
    if store.session.is_streaming? do
      {:reply, {:error, :already_streaming}, store}
    else
      {:reply, :ok, stub_run(store)}
    end
  end

  def handle_call({:steer, msg}, _from, store) do
    q = enqueue(store.session.steering_queue, msg)
    {:reply, :ok, put_in(store.session.steering_queue, q)}
  end

  def handle_call({:follow_up, msg}, _from, store) do
    q = enqueue(store.session.follow_up_queue, msg)
    {:reply, :ok, put_in(store.session.follow_up_queue, q)}
  end

  def handle_call(:abort, _from, store) do
    if store.session.is_streaming? do
      # With no real loop yet, we just flip idle and emit an aborted
      # AgentEnd. Real cancellation wiring lands in octo-z1d.6.
      Subscribers.dispatch(
        self(),
        %Event.AgentEnd{reason: :aborted, messages: store.session.messages}
      )

      {:reply, :ok, idle(%{store | session: %{store.session | error_message: "aborted"}})}
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

  # ---------- internal helpers (stubbed) ----------

  # Stub run: emits AgentStart + AgentEnd{reason: :stop} synchronously
  # via the subscriber dispatcher. Real loop lands in octo-z1d.3.
  defp stub_run(store) do
    session_pid = self()
    session = %{store.session | is_streaming?: true, error_message: nil}
    Subscribers.dispatch(session_pid, %Event.AgentStart{})

    Subscribers.dispatch(
      session_pid,
      %Event.AgentEnd{reason: :stop, messages: session.messages}
    )

    idle(%{store | session: session})
  end

  defp idle(store) do
    store = %{store | session: %{store.session | is_streaming?: false}}
    for from <- Enum.reverse(store.idle_waiters), do: GenServer.reply(from, :ok)
    %{store | idle_waiters: []}
  end

  # Enqueue into a PendingMessageQueue. The full behaviour (bound
  # checks, modes, draining) lands in octo-z1d.5; for this ticket
  # we just need enqueue + count for state assertions.
  defp enqueue(queue, msg) do
    %{queue | items: :queue.in(msg, queue.items), count: queue.count + 1}
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
