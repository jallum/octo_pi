defmodule OctoPi.AI.Event.ToolCallEnd do
  @moduledoc """
  A tool-use content block has finished. `tool_call` is the finalized
  `ToolCall` struct with fully-parsed `arguments`.
  """

  alias OctoPi.AI.{Message.Assistant, ToolCall}

  @enforce_keys [:content_index, :tool_call, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          tool_call: ToolCall.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :tool_call, :partial]
end
