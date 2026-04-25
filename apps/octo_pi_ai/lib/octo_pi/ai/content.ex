defmodule OctoPi.AI.Content do
  @moduledoc """
  Content blocks that appear inside `Message.User` and `Message.Assistant`.

  Text and Thinking blocks stream in deltas; Image blocks are always
  complete. See `OctoPi.AI.Content.Text`, `OctoPi.AI.Content.Thinking`,
  `OctoPi.AI.Content.Image`, and `OctoPi.AI.ToolCall` (the tool-use
  variant, which lives at the top level because it is also referenced
  directly in events).
  """

  alias OctoPi.AI.Content.Image
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Content.Thinking
  alias OctoPi.AI.ToolCall

  @type assistant_block :: Text.t() | Thinking.t() | ToolCall.t()
  @type user_block :: Text.t() | Image.t()
end
