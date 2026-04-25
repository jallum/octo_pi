defmodule OctoPi.AI.Message do
  @moduledoc """
  The message union stored in a `Context`:

  - `Message.User` — human input (text and/or images).
  - `Message.Assistant` — model output (text, thinking, tool calls).
  - `Message.ToolResult` — the outcome of a tool call, fed back to the
    model on the next turn.
  """

  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  @type t :: User.t() | Assistant.t() | ToolResult.t()
end
