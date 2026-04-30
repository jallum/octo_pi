defmodule OctoPi.AI.Message.User do
  @moduledoc """
  A user message. `content` is a list of text/image blocks; bare
  strings reach this struct only via `OctoPi.Agent.Message.normalize/1`
  which lifts them into `[%OctoPi.AI.Content.Text{text: ...}]` (see
  opi-5ka). `timestamp` is Unix milliseconds.
  """

  alias OctoPi.AI.Content

  @enforce_keys [:content, :timestamp]
  @type t :: %__MODULE__{
          content: [Content.user_block()],
          timestamp: integer()
        }

  defstruct [:content, :timestamp]
end
