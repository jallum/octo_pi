defmodule OctoPi.Agent.Event do
  @moduledoc """
  Canonical event union emitted by an agent session. Mirrors
  pi-agent-core's `AgentEvent` (`types.ts` L349-364).

  Lifecycle (high level):

      AgentStart
        TurnStart
          MessageStart → many MessageUpdate → MessageEnd
          ToolExecutionStart → many ToolExecutionUpdate → ToolExecutionEnd
          (repeat per tool)
        TurnEnd
        (repeat per turn until the loop exits)
      AgentEnd

  `partial` fields, where present, carry the in-progress
  `OctoPi.AI.Message.Assistant.t()` snapshot — consumers can render
  current state without tracking deltas themselves. `message` (on
  `MessageEnd`, `AgentEnd`) carries the finalized shape.

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
          | Event.MessageUpdate.t()
          | Event.MessageEnd.t()
          | Event.ToolExecutionStart.t()
          | Event.ToolExecutionUpdate.t()
          | Event.ToolExecutionEnd.t()

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

  defmodule MessageUpdate do
    @moduledoc "Assistant message partial snapshot mid-stream."
    @enforce_keys [:partial]
    @type t :: %__MODULE__{partial: Assistant.t()}
    defstruct [:partial]
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
end
