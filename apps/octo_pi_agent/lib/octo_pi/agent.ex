defmodule OctoPi.Agent do
  @moduledoc """
  Phase 2 — the stateful agent kernel. Ported from pi-agent-core.

  Start a session with `start_session/1`, then drive it with
  `prompt/2`, `continue/1`, `steer/2`, `follow_up/2`, and `abort/1`.
  Observe events with `subscribe/3`; read state with `state/1`; wait
  for a run to finish with `wait_for_idle/2`.

  Subscriber modes:
    - `:sync` — Session uses `GenServer.call` (5s timeout); honors
      pi-agent-core's listener-barrier semantics.
    - `:async` — `send/2` fire-and-forget; cheap for UI or logging.

  At this ticket (`octo-z1d.2`) the run itself is stubbed — prompt
  and continue emit `AgentStart` + `AgentEnd{reason: :stop}` without
  calling the LLM. The full loop lands in `octo-z1d.3`.

  See `docs/port-map/agent.md` for the full porting spec.
  """

  alias OctoPi.Agent.Message
  alias OctoPi.Agent.Session
  alias OctoPi.Agent.Session.State
  alias OctoPi.Agent.Subscribers

  @type session :: pid()
  @type subscribe_mode :: :sync | :async

  @doc """
  Start a session GenServer. Required opts: `:model`. Optional:
  `:system_prompt`, `:tools`, `:thinking_level`, `:transport`,
  `:before_tool_call`, `:after_tool_call`, `:messages`.
  """
  @spec start_session(keyword()) :: {:ok, session()}
  def start_session(opts) when is_list(opts), do: Session.start_link(opts)

  @doc "Append message(s) to the transcript and start a new run."
  @spec prompt(session(), String.t() | Message.t() | [Message.t() | String.t()]) ::
          :ok | {:error, :already_streaming}
  def prompt(pid, msg_or_msgs), do: Session.prompt(pid, msg_or_msgs)

  @doc "Continue the current conversation with no new user input."
  @spec continue(session()) :: :ok | {:error, :already_streaming}
  def continue(pid), do: Session.continue(pid)

  @doc "Enqueue a message for injection before the next LLM call of the current run."
  @spec steer(session(), String.t() | Message.t()) :: :ok | {:error, :full}
  def steer(pid, msg), do: Session.steer(pid, msg)

  @doc "Enqueue a message for injection when the current run would otherwise stop."
  @spec follow_up(session(), String.t() | Message.t()) :: :ok | {:error, :full}
  def follow_up(pid, msg), do: Session.follow_up(pid, msg)

  @doc """
  Switch the drainage mode of one of the session's pending-message
  queues. `:one_at_a_time` drains one item per pass; `:all` drains
  every queued item in one shot.
  """
  @spec set_queue_mode(session(), :steering | :follow_up, :one_at_a_time | :all) :: :ok
  def set_queue_mode(pid, queue, mode), do: Session.set_queue_mode(pid, queue, mode)

  @doc "Abort the current run. No-op if the session is idle."
  @spec abort(session()) :: :ok
  def abort(pid), do: Session.abort(pid)

  @doc """
  Request a manual compaction. Fire-and-forget — returns `:ok`
  immediately (or `{:error, :busy}` if a run or compaction is already
  in flight).

  Session emits `%Event.CompactionRequested{ref, opts}` to subscribers;
  exactly one subscriber performs the work and calls
  `compaction_response/3` when done. Session then emits
  `%Event.CompactionEnd{result}` to all subscribers. Callers who need
  to synchronize use `wait_for_idle/2` or watch for `CompactionEnd`.
  """
  @spec compact(session(), keyword()) :: :ok | {:error, :busy}
  def compact(pid, opts \\ []), do: Session.compact(pid, opts)

  @doc """
  Subscriber-side response API for `%Event.CompactionRequested{}`.
  Synchronous on the responder — caller blocks until Agent has
  threaded the result through Turn and replied to the original
  `compact/1` caller.

  Returns `:ok` on success, `{:error, :stale}` if the ref doesn't
  match Agent's currently active compaction (e.g. the request was
  superseded or the agent was aborted).
  """
  @spec compaction_response(session(), reference(), term()) ::
          :ok | {:error, :stale}
  def compaction_response(pid, ref, result),
    do: Session.compaction_response(pid, ref, result)

  @doc "Change the thinking level for future runs."
  @spec set_thinking_level(session(), atom()) :: :ok
  def set_thinking_level(pid, level), do: Session.set_thinking_level(pid, level)

  @doc "Change the model for future runs."
  @spec set_model(session(), OctoPi.AI.Model.t()) :: :ok
  def set_model(pid, model), do: Session.set_model(pid, model)

  @doc "Add a tool to the session's active tool list. No-op if a tool with the same name already exists."
  @spec add_tool(session(), map()) :: :ok
  def add_tool(pid, tool), do: Session.add_tool(pid, tool)

  @doc "Drain all messages from the steering queue and return them."
  @spec drain_steering(session()) :: [Message.t()]
  def drain_steering(pid), do: Session.drain_steering(pid)

  @doc "Drain all messages from the follow-up queue and return them."
  @spec drain_follow_up(session()) :: [Message.t()]
  def drain_follow_up(pid), do: Session.drain_follow_up(pid)

  @doc """
  Subscribe `listener_pid` to session events. Returns an unsubscribe
  function. The 1- and 2-arity forms default the listener to
  `self()`.
  """
  @spec subscribe(session()) :: (-> :ok)
  def subscribe(session_pid), do: subscribe(session_pid, self(), :async)

  @spec subscribe(session(), subscribe_mode()) :: (-> :ok)
  def subscribe(session_pid, mode) when mode in [:sync, :async] do
    subscribe(session_pid, self(), mode)
  end

  @spec subscribe(session(), pid(), subscribe_mode()) :: (-> :ok)
  def subscribe(session_pid, listener_pid, mode) when is_pid(listener_pid) do
    Subscribers.subscribe(session_pid, listener_pid, mode)
  end

  @doc "Read the session's current state."
  @spec state(session()) :: State.t()
  def state(pid), do: Session.state(pid)

  @doc "Block until the session is idle, or timeout."
  @spec wait_for_idle(session(), timeout()) :: :ok | :timeout
  def wait_for_idle(pid, timeout \\ 30_000) do
    Session.wait_for_idle(pid, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
  end
end
