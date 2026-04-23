defmodule OctoPi.AI.Message.User do
  @moduledoc """
  A user message. `content` is either a plain string (shorthand for a
  single text block) or a list of text/image blocks. `timestamp` is
  Unix milliseconds.
  """

  alias OctoPi.AI.Content

  @enforce_keys [:content, :timestamp]
  @type t :: %__MODULE__{
          content: String.t() | [Content.user_block()],
          timestamp: integer()
        }

  defstruct [:content, :timestamp]
end
