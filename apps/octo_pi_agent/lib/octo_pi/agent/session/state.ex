defmodule OctoPi.Agent.Session.State do
  @moduledoc """
  Per-session state held by the Session GenServer.

  Fields:
    * `:system_prompt`     — prefixed to every LLM call
    * `:model`             — the active provider model
    * `:thinking_level`    — reasoning-effort knob
    * `:tools`             — per-session list of active tools; can be mutated at runtime
    * `:session_manager`   — ordered transcript and session history as a `SessionManager.t()`
    * `:is_streaming?`     — true while a run is in flight
    * `:streaming_message` — partial assistant message during stream
    * `:pending_tool_calls` — ids of tools currently executing
    * `:error_message`     — last failure reason from a run
    * `:steering_queue` / `:follow_up_queue` — `PendingMessageQueue.t()`
    * `:loop_task`         — pid of the running loop, or nil
    * `:abort_ref`         — `AbortRef.t()` for the current run, or nil
    * `:run_started_at_mono` — monotonic start time of the current run, nil when idle
    * `:before_tool_call` / `:after_tool_call` — optional hooks
    * `:transport`         — `OctoPi.Agent.Transport` impl module
    * `:is_compacting?`    — true while a compaction is in progress
    * `:overflow_recovery_attempted?` — prevents infinite compaction retry loops
    * `:compaction_task` — running compaction task, or nil when idle
    * `:base_system_prompt` — preserved base prompt; extensions can override per-turn system_prompt
    * `:tool_registry`     — all registered tools by name; :tools is a filtered view of this
    * `:extension_runner`  — pid of the ExtensionRunner for this session, or nil
  """

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.Tool
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
          session_manager: SessionManager.t(),
          is_streaming?: boolean(),
          streaming_message: Assistant.t() | nil,
          pending_tool_calls: MapSet.t(),
          error_message: String.t() | nil,
          steering_queue: PendingMessageQueue.t(),
          follow_up_queue: PendingMessageQueue.t(),
          loop_task: pid() | nil,
          abort_ref: AbortRef.t() | nil,
          run_started_at_mono: integer() | nil,
          before_tool_call: before_tool_call() | nil,
          after_tool_call: after_tool_call() | nil,
          transport: module(),
          is_compacting?: boolean(),
          overflow_recovery_attempted?: boolean(),
          compaction_task: Task.t() | nil,
          base_system_prompt: String.t() | nil,
          tool_registry: %{String.t() => Tool.t()},
          extension_runner: pid() | nil,
          compaction_queue: [[term()]]
        }

  defstruct [
    :system_prompt,
    :model,
    :streaming_message,
    :error_message,
    :loop_task,
    :abort_ref,
    :run_started_at_mono,
    :before_tool_call,
    :after_tool_call,
    :transport,
    :base_system_prompt,
    :compaction_task,
    :extension_runner,
    thinking_level: :off,
    tools: [],
    session_manager: %SessionManager{},
    is_streaming?: false,
    is_compacting?: false,
    overflow_recovery_attempted?: false,
    pending_tool_calls: MapSet.new(),
    steering_queue: %PendingMessageQueue{items: :queue.new()},
    follow_up_queue: %PendingMessageQueue{items: :queue.new()},
    tool_registry: %{},
    compaction_queue: []
  ]
end
