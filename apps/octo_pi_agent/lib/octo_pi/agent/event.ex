defmodule OctoPi.Agent.Event do
  @moduledoc """
  Canonical event union emitted by an agent loop. Mirrors
  pi-agent-core's `AgentEvent` (`types.ts` L349-364).

  Lifecycle (high level):

      AgentStart
        TurnStart
          MessageStart
            MessageBlockStart → many MessageBlockDelta → MessageBlockEnd
            (repeat per content block: text / thinking / tool_call)
          MessageEnd
          ToolExecutionStart → many ToolExecutionUpdate → ToolExecutionEnd
          (repeat per tool)
        TurnEnd
        (repeat per turn until the loop exits)
      AgentEnd

  `QueueUpdate` is asynchronous: it fires whenever the steering or
  follow-up queue is mutated (enqueue, public-API drain, in-loop
  drain). It is not part of the per-turn lifecycle above and may
  arrive at any time, including before `AgentStart` and after
  `AgentEnd`.

  `MessageStart`'s `partial` carries the empty Assistant skeleton
  (model/provider metadata, no content yet). Per-chunk updates ride
  on `MessageBlockDelta` as `{block_id, kind, delta, snapshot}` — both
  `delta` and `snapshot` are binaries (refcounted refc binaries cross
  processes zero-copy). `message` (on `MessageEnd`, `AgentEnd`) carries
  the finalized full shape — the only point in the stream where a
  full `Assistant.t()` crosses a process boundary.

  `ToolExecutionUpdate` carries a `Tool.Result.t()` partial — tool
  handlers can stream progress via the `on_update` callback.
  """

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Message
  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Message.Assistant

  @type t ::
          Event.AgentStart.t()
          | Event.AgentEnd.t()
          | Event.TurnStart.t()
          | Event.TurnEnd.t()
          | Event.MessageStart.t()
          | Event.MessageBlockStart.t()
          | Event.MessageBlockDelta.t()
          | Event.MessageBlockEnd.t()
          | Event.MessageEnd.t()
          | Event.ToolExecutionStart.t()
          | Event.ToolExecutionUpdate.t()
          | Event.ToolExecutionEnd.t()
          | Event.CompactionRequested.t()
          | Event.CompactionEnd.t()
          | Event.QueueUpdate.t()

  defmodule AgentStart do
    @moduledoc "Emitted once at the start of a run."
    defstruct []
    @type t :: %__MODULE__{}
  end

  defmodule AgentEnd do
    @moduledoc """
    Terminal event. `reason` reflects the assistant's final stop
    reason (`:stop | :length | :tool_use | :error | :aborted`).
    `messages` is the final transcript snapshot.
    """
    @type reason :: :stop | :length | :tool_use | :error | :aborted
    @enforce_keys [:reason, :messages]
    @type t :: %__MODULE__{reason: reason(), messages: [Message.t()]}
    defstruct [:reason, :messages]
  end

  defmodule TurnStart do
    @moduledoc "A turn (one LLM call + its tool batch) has started."
    @enforce_keys [:turn]
    @type t :: %__MODULE__{turn: non_neg_integer()}
    defstruct [:turn]
  end

  defmodule TurnEnd do
    @moduledoc "A turn ended — all tools in the batch finished."
    @enforce_keys [:turn]
    @type t :: %__MODULE__{turn: non_neg_integer()}
    defstruct [:turn]
  end

  defmodule MessageStart do
    @moduledoc "Assistant message streaming has begun."
    @enforce_keys [:partial]
    @type t :: %__MODULE__{partial: Assistant.t()}
    defstruct [:partial]
  end

  defmodule MessageBlockStart do
    @moduledoc """
    A single content block (text / thinking / tool_call) has begun
    streaming. `block_id` is the decoder's `content_index` — a stable
    forward-order integer per assistant message. `kind` discriminates
    the block type.
    """
    @enforce_keys [:block_id, :kind]
    @type kind :: :text | :thinking | :tool_call
    @type t :: %__MODULE__{block_id: non_neg_integer(), kind: kind()}
    defstruct [:block_id, :kind]
  end

  defmodule MessageBlockDelta do
    @moduledoc """
    An incremental chunk for a content block. `delta` is the new
    fragment for this chunk; `snapshot` is the cumulative text of
    *this block* so far (delta inclusive).

    For `:tool_call`, `delta` is a JSON fragment and `snapshot` is
    the accumulated partial-JSON buffer.

    Both are refcounted refc binaries — zero-copy across processes.
    """
    @enforce_keys [:block_id, :kind, :delta, :snapshot]
    @type kind :: :text | :thinking | :tool_call
    @type t :: %__MODULE__{
            block_id: non_neg_integer(),
            kind: kind(),
            delta: binary(),
            snapshot: binary()
          }
    defstruct [:block_id, :kind, :delta, :snapshot]
  end

  defmodule MessageBlockEnd do
    @moduledoc """
    A content block has finished. `content` is the full accumulated
    text (or partial-JSON buffer for `:tool_call`).
    """
    @enforce_keys [:block_id, :kind, :content]
    @type kind :: :text | :thinking | :tool_call
    @type t :: %__MODULE__{
            block_id: non_neg_integer(),
            kind: kind(),
            content: binary()
          }
    defstruct [:block_id, :kind, :content]
  end

  defmodule MessageEnd do
    @moduledoc "Assistant message finalized."
    @enforce_keys [:message]
    @type t :: %__MODULE__{message: Assistant.t()}
    defstruct [:message]
  end

  defmodule ToolExecutionStart do
    @moduledoc "A tool call has been dispatched."
    @enforce_keys [:tool_call_id, :tool_name]
    @type t :: %__MODULE__{tool_call_id: String.t(), tool_name: String.t(), args: map()}
    defstruct [:tool_call_id, :tool_name, args: %{}]
  end

  defmodule ToolExecutionUpdate do
    @moduledoc "Tool handler reported a partial result via on_update."
    @enforce_keys [:tool_call_id, :partial]
    @type t :: %__MODULE__{tool_call_id: String.t(), partial: Tool.Result.t()}
    defstruct [:tool_call_id, :partial]
  end

  defmodule ToolExecutionEnd do
    @moduledoc "A tool call finished (successfully or with an error)."
    @enforce_keys [:tool_call_id, :tool_name, :result]
    @type t :: %__MODULE__{
            tool_call_id: String.t(),
            tool_name: String.t(),
            result: Tool.Result.t()
          }
    defstruct [:tool_call_id, :tool_name, :result]
  end

  defmodule CompactionRequested do
    @moduledoc """
    Emitted when the Loop enters the `:compacting` Turn state.
    Exactly one subscriber is expected to perform the compaction and
    respond via `OctoPi.Agent.compaction_response/3`. The `ref`
    carried here matches the one Loop will check on the response —
    late or stale responses get rejected.

    `opts` is the keyword list passed to `OctoPi.Agent.compact/2`,
    forwarded verbatim. Subscribers interpret it (e.g. the Coder app
    forwards `:custom_instructions`, `:thinking_level`, etc. into
    `Coder.Session.compact/2`).
    """
    @enforce_keys [:ref, :opts]
    @type t :: %__MODULE__{ref: reference(), opts: keyword()}
    defstruct [:ref, :opts]
  end

  defmodule CompactionEnd do
    @moduledoc """
    Emitted when a compaction completes (success, cancel, or error).
    Subscribers and callers observe this event to know the outcome —
    `OctoPi.Agent.compact/2` returns immediately so callers must
    watch the event stream (or use `wait_for_idle/2`) to synchronize.

    `result` mirrors the shape returned by the responder:
    `{:ok, summary_data} | {:cancel, reason} | {:error, reason}`.
    """
    @enforce_keys [:result]
    @type t :: %__MODULE__{result: {:ok, map()} | {:cancel, term()} | {:error, term()}}
    defstruct [:result]
  end

  defmodule QueueUpdate do
    @moduledoc """
    Emitted whenever the steering or follow-up queue changes — on
    enqueue (`steer/2` / `follow_up/2`), on public-API drain
    (`drain_steering/1` / `drain_follow_up/1`), and on every in-loop
    drain. Subscribers (notably the TUI's pending-messages indicator)
    use this to render "Steering: …" / "Follow-up: …" lines above the
    editor without having to call back into the Agent for state.

    Both queues are reported in FIFO order (oldest first) at every
    emission.

    Mirrors upstream pi-mono's `queue_update` event emitted by
    `AgentSession` (tmp/pi-mono/packages/coding-agent/src/core
    /agent-session.ts).
    """
    @enforce_keys [:steering, :follow_up]
    @type t :: %__MODULE__{steering: [Message.t()], follow_up: [Message.t()]}
    defstruct [:steering, :follow_up]
  end
end
