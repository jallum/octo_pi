defmodule OctoPi.Agent do
  @moduledoc """
  Phase 2 — the stateful agent kernel. Ported from pi-agent-core.

  Start a loop with `start_loop/1`, then drive it with
  `prompt/2`, `continue/1`, `steer/2`, `follow_up/2`, and `abort/1`.
  Observe events with `subscribe/3`; read state with `state/1`; wait
  for a run to finish with `wait_for_idle/2`.

  Subscriber modes:
    - `:sync` — Loop uses `GenServer.call` (5s timeout); honors
      pi-agent-core's listener-barrier semantics.
    - `:async` — `send/2` fire-and-forget; cheap for UI or logging.

  At this ticket (`octo-z1d.2`) the run itself is stubbed — prompt
  and continue emit `AgentStart` + `AgentEnd{reason: :stop}` without
  calling the LLM. The full loop lands in `octo-z1d.3`.

  See `docs/port-map/agent.md` for the full porting spec.
  """

  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.Message
  alias OctoPi.Agent.Subscribers
  alias OctoPi.AI.Model

  @opaque t :: pid()
  @type subscribe_mode :: :sync | :async

  @type loop_opts :: [
          model: Model.t(),
          system_prompt: String.t(),
          tools: [OctoPi.Agent.Tool.t()],
          thinking_level: OctoPi.AI.thinking_level() | :off,
          transport: module(),
          before_tool_call: (map() -> :allow | {:block, term()}),
          after_tool_call: (map() -> :unchanged | {:patch, map()}),
          convert_to_llm: ([term()] -> [OctoPi.AI.Message.t()]),
          messages: [OctoPi.AI.Message.t()],
          auto_compact_reserve_tokens: pos_integer(),
          steering_queue_bound: pos_integer(),
          follow_up_queue_bound: pos_integer()
        ]

  @doc """
  Start a loop GenServer.

  Required: `:model`. All others are optional.
  """
  @spec start_loop(loop_opts()) :: {:ok, t()}
  def start_loop(opts) when is_list(opts), do: Loop.start_link(opts)

  @doc "Append message(s) to the transcript and start a new run."
  @spec prompt(t(), String.t() | Message.t() | [Message.t() | String.t()]) :: :ok | {:error, :already_streaming}
  def prompt(pid, msg_or_msgs), do: Loop.prompt(pid, msg_or_msgs)

  @doc "Continue the current conversation with no new user input."
  @spec continue(t()) :: :ok | {:error, :already_streaming}
  def continue(pid), do: Loop.continue(pid)

  @doc "Enqueue a message for injection before the next LLM call of the current run."
  @spec steer(t(), String.t() | Message.t()) :: :ok | {:error, :full}
  def steer(pid, msg), do: Loop.steer(pid, msg)

  @doc "Enqueue a message for injection when the current run would otherwise stop."
  @spec follow_up(t(), String.t() | Message.t()) :: :ok | {:error, :full}
  def follow_up(pid, msg), do: Loop.follow_up(pid, msg)

  @doc """
  Switch the drainage mode of one of the loop's pending-message
  queues. `:one_at_a_time` drains one item per pass; `:all` drains
  every queued item in one shot.
  """
  @spec set_queue_mode(t(), :steering | :follow_up, :one_at_a_time | :all) :: :ok
  def set_queue_mode(pid, queue, mode), do: Loop.set_queue_mode(pid, queue, mode)

  @doc "Abort the current run. No-op if the loop is idle."
  @spec abort(t()) :: :ok
  def abort(pid), do: Loop.abort(pid)

  @doc """
  Request a manual compaction. Fire-and-forget — returns `:ok`
  immediately (or `{:error, :busy}` if a run or compaction is already
  in flight).

  Loop emits `%Event.CompactionRequested{ref, opts}` to subscribers;
  exactly one subscriber performs the work and calls
  `compaction_response/3` when done. Loop then emits
  `%Event.CompactionEnd{result}` to all subscribers. Callers who need
  to synchronize use `wait_for_idle/2` or watch for `CompactionEnd`.
  """
  @spec compact(t(), keyword()) :: :ok | {:error, :busy}
  def compact(pid, opts \\ []), do: Loop.compact(pid, opts)

  @doc """
  Subscriber-side response API for `%Event.CompactionRequested{}`.
  Synchronous on the responder — caller blocks until Agent has
  threaded the result through Turn and replied to the original
  `compact/1` caller.

  Returns `:ok` on success, `{:error, :stale}` if the ref doesn't
  match Agent's currently active compaction (e.g. the request was
  superseded or the agent was aborted).
  """
  @spec compaction_response(t(), reference(), term()) :: :ok | {:error, :stale}
  def compaction_response(pid, ref, result), do: Loop.compaction_response(pid, ref, result)

  @doc "Change the thinking level for future runs."
  @spec set_thinking_level(t(), atom()) :: :ok
  def set_thinking_level(pid, level), do: Loop.set_thinking_level(pid, level)

  @doc "Change the model for future runs."
  @spec set_model(t(), Model.t()) :: :ok
  def set_model(pid, model), do: Loop.set_model(pid, model)

  @doc "Add a tool to the loop's active tool list. No-op if a tool with the same name already exists."
  @spec add_tool(t(), map()) :: :ok
  def add_tool(pid, tool), do: Loop.add_tool(pid, tool)

  @doc "Drain all messages from the steering queue and return them."
  @spec drain_steering(t()) :: [Message.t()]
  def drain_steering(pid), do: Loop.drain_steering(pid)

  @doc "Drain all messages from the follow-up queue and return them."
  @spec drain_follow_up(t()) :: [Message.t()]
  def drain_follow_up(pid), do: Loop.drain_follow_up(pid)

  @doc """
  Subscribe `listener_pid` to loop events. Returns an unsubscribe
  function. The 1- and 2-arity forms default the listener to
  `self()`.
  """
  @spec subscribe(t()) :: (-> :ok)
  def subscribe(loop_pid), do: subscribe(loop_pid, self(), :async)

  @spec subscribe(t(), subscribe_mode()) :: (-> :ok)
  def subscribe(loop_pid, mode) when mode in [:sync, :async], do: subscribe(loop_pid, self(), mode)

  @spec subscribe(t(), pid(), subscribe_mode()) :: (-> :ok)
  def subscribe(loop_pid, listener_pid, mode) when is_pid(listener_pid),
    do: Subscribers.subscribe(loop_pid, listener_pid, mode)

  @doc "Block until the loop is idle, or timeout."
  @spec wait_for_idle(t(), timeout()) :: :ok | :timeout
  def wait_for_idle(pid, timeout \\ 30_000) do
    Loop.wait_for_idle(pid, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
  end
end
