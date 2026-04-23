defmodule OctoPi.AI.Message.ToolResult do
  @moduledoc """
  The result of a tool execution, fed back to the model on the next
  turn. `content` is a list of text/image blocks. `details` carries
  optional provider-opaque state. `timestamp` is Unix milliseconds.
  """

  alias OctoPi.AI.Content

  @enforce_keys [:tool_call_id, :tool_name, :content, :is_error?, :timestamp]
  @type t :: %__MODULE__{
          tool_call_id: String.t(),
          tool_name: String.t(),
          content: [Content.user_block()],
          details: term() | nil,
          is_error?: boolean(),
          timestamp: integer()
        }

  defstruct [:tool_call_id, :tool_name, :content, :details, :is_error?, :timestamp]
end
