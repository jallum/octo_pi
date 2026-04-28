defmodule OctoPi.Agent.Session.State do
  @moduledoc """
  Per-session state held by the Session GenServer. Ported from
  pi-agent-core's `Agent` class state (see `docs/port-map/agent.md`
  §1). This ticket (`octo-z1d.1`) only pins the struct shape — the
  Session GenServer that manipulates it lands in `octo-z1d.2`, and
  the loop / queues / cancellation layers fill in behaviour in later
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
    * `:messages_provider` — optional 1-arity closure
      `(Session.State -> [Message.t()])` used to build the per-turn
      LLM messages list. `nil` falls back to
      `MessageLog.to_list(state.messages)`. The coder app passes a
      closure that delegates to
      `OctoPi.Coder.Session.build_session_context/1` |>
      `OctoPi.Coder.Session.Messages.to_llm/1` so prompt assembly
      reflects post-compaction kept-window + synthetic summary.
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

  @enforce_keys [:model, :transport]
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
          messages_provider: (t() -> [term()]) | nil,
          compaction_auto?: false | :continue | :end_after | :overflow_retry,
          auto_compact_reserve_tokens: non_neg_integer() | nil,
          last_compaction_at_ms: integer() | nil,
          compaction_overflow_attempted?: boolean()
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
    :before_tool_call,
    :after_tool_call,
    :transport,
    :messages_provider,
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
