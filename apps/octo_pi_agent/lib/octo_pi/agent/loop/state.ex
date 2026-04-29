defmodule OctoPi.Agent.Loop.State do
  @moduledoc """
  Per-loop state held by the Loop GenServer. Ported from
  pi-agent-core's `Agent` class state (see `docs/port-map/agent.md`
  §1). This ticket (`octo-z1d.1`) only pins the struct shape — the
  Loop GenServer that manipulates it lands in `octo-z1d.2`, and
  the queues / cancellation layers fill in behaviour in later
  children.

  Fields:
    * `:system_prompt` — prefixed to every LLM call
    * `:model` — the active provider model
    * `:thinking_level` — reasoning-effort knob
    * `:tools` — per-session list; can be mutated at runtime
    * `:messages` — ordered transcript, stored as a `MessageLog.t()`
      (oldest-first semantics; convert to a plain list with
      `MessageLog.to_list/1`)
    * `:is_streaming?` — true while a run is in flight
    * `:streaming_message` — partial assistant message during stream
    * `:pending_tool_calls` — ids of tools currently executing
    * `:error_message` — last failure reason from a run
    * `:steering_queue` / `:follow_up_queue` — `PendingMessageQueue.t()`
    * `:turn` — `OctoPi.Agent.Turn.t()`, the per-turn FSM
    * `:turn_pid` — pid of the active stream/tool-batch Task, or nil
    * `:turn_ref` — ref tagging messages from the active Task; used to
      drop late messages from a killed/cancelled Task. nil when idle.
    * `:abort_ref` — `AbortRef.t()` for the current run, or nil
    * `:run_started_at_mono` — monotonic start time of the current run, nil when idle
    * `:before_tool_call` / `:after_tool_call` — optional hooks
    * `:transport` — `OctoPi.Agent.Transport` impl module
    * `:convert_to_llm` — required 1-arity transform applied to the
      transcript at LLM-call time, `([AgentMessage] -> [Message])`.
      Stateless. The Coder app passes
      `&OctoPi.Coder.Session.Messages.to_llm/1` to flatten synthetic
      message types (CompactionSummaryMessage, BranchSummaryMessage)
      into LLM-shaped user messages. Callers that don't have synthetic
      types pass `&Function.identity/1`.
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.MessageLog
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Turn
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model

  @type thinking_level :: :off | :minimal | :low | :medium | :high | :xhigh

  @type before_tool_call ::
          (map() ->
             {:block, reason :: String.t()} | :allow)

  @type after_tool_call ::
          (map() -> {:patch, map()} | :unchanged)

  @enforce_keys [:model, :transport, :convert_to_llm]
  @type t :: %__MODULE__{
          system_prompt: String.t() | nil,
          model: Model.t(),
          thinking_level: thinking_level(),
          tools: [Tool.t()],
          messages: MessageLog.t(),
          is_streaming?: boolean(),
          streaming_message: Assistant.t() | nil,
          pending_tool_calls: MapSet.t(),
          error_message: String.t() | nil,
          steering_queue: PendingMessageQueue.t(),
          follow_up_queue: PendingMessageQueue.t(),
          turn: Turn.t(),
          turn_pid: pid() | nil,
          turn_ref: reference() | nil,
          abort_ref: AbortRef.t() | nil,
          run_started_at_mono: integer() | nil,
          before_tool_call: before_tool_call() | nil,
          after_tool_call: after_tool_call() | nil,
          transport: module(),
          convert_to_llm: ([term()] -> [term()]),
          compaction_auto?: false | :continue | :end_after | :overflow_retry,
          auto_compact_reserve_tokens: non_neg_integer() | nil,
          last_compaction_at_ms: integer() | nil,
          compaction_overflow_attempted?: boolean(),
          session_id: String.t() | nil
        }

  defstruct [
    :system_prompt,
    :model,
    :streaming_message,
    :error_message,
    :turn_pid,
    :turn_ref,
    :abort_ref,
    :run_started_at_mono,
    :session_id,
    :before_tool_call,
    :after_tool_call,
    :transport,
    :convert_to_llm,
    :auto_compact_reserve_tokens,
    :last_compaction_at_ms,
    turn: %Turn{},
    thinking_level: :off,
    tools: [],
    messages: %MessageLog{},
    is_streaming?: false,
    pending_tool_calls: MapSet.new(),
    steering_queue: %PendingMessageQueue{items: :queue.new()},
    follow_up_queue: %PendingMessageQueue{items: :queue.new()},
    compaction_auto?: false,
    compaction_overflow_attempted?: false
  ]
end
