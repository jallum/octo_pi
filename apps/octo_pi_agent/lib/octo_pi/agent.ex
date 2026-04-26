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
  Manually trigger context compaction. Returns `:ok` immediately; compaction
  runs asynchronously. Emits `CompactionStart` then `CompactionEnd` when done.

  Options:
    - `:keep_recent_tokens` — token budget to keep (default 8000)
    - `:model` — override model for summarization (default session model)
  """
  @spec compact(session(), keyword()) :: :ok | {:error, :streaming | :already_compacting}
  def compact(pid, opts \\ []), do: Session.compact(pid, opts)

  @doc "Register an extension module with the session's ExtensionRunner."
  @spec register_extension(session(), module()) :: :ok
  def register_extension(pid, module), do: Session.register_extension(pid, module)

  @doc "Emit a hook event through the session's ExtensionRunner. Returns :ok if no runner is configured."
  @spec emit_hook(session(), atom(), map()) :: :ok | {:cancelled, term()} | {:modified, map()}
  def emit_hook(pid, event_type, payload), do: Session.emit_hook(pid, event_type, payload)

  @doc "Add a tool to the session's tool registry (does not activate it)."
  @spec register_tool(session(), map()) :: :ok
  def register_tool(pid, tool), do: Session.register_tool(pid, tool)

  @doc "Activate the given tool names from the tool registry as the session's active tool set."
  @spec set_active_tools(session(), [String.t()]) :: :ok
  def set_active_tools(pid, tool_names), do: Session.set_active_tools(pid, tool_names)

  @doc "Return the names of the currently active tools."
  @spec get_active_tool_names(session()) :: [String.t()]
  def get_active_tool_names(pid), do: Session.get_active_tool_names(pid)

  @doc "Return the registered slash-command handlers, or %{} if no extension runner."
  @spec get_commands(session()) :: %{String.t() => (String.t() -> :ok)}
  def get_commands(pid), do: Session.get_commands(pid)

  @doc "Fork the session to an earlier entry. Returns {:error, :not_found} if entry_id is unknown."
  @spec fork(session(), String.t()) :: :ok | {:error, :not_found}
  def fork(pid, entry_id), do: Session.fork(pid, entry_id)

  @doc """
  Navigate the session tree to an earlier entry.

  Options:
    - `summarize: true` — LLM-summarize the abandoned branch and append a
      `BranchSummaryEntry` before moving the leaf pointer.
    - `custom_instructions` — additional instructions for the LLM summarizer.

  Returns `{:error, :not_found}` if `target_id` is unknown.
  """
  @spec navigate_tree(session(), String.t(), keyword()) :: :ok | {:error, :not_found}
  def navigate_tree(pid, target_id, opts \\ []), do: Session.navigate_tree(pid, target_id, opts)

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
