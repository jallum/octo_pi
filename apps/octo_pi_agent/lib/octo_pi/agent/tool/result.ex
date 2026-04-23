defmodule OctoPi.Agent.Tool.Result do
  @moduledoc """
  Return value from a tool handler. Matches pi-agent-core's
  `AgentToolResult` (`types.ts` L320-330).

  - `content` is what the model will see on the next turn; a list of
    text/image content blocks matching `OctoPi.AI.Content.user_block()`.
  - `details` is opaque structured data the tool captures for logs /
    UI renderers / extensions; never shown to the LLM.
  - `is_error?` flags expected failures (e.g. "file not found");
    they still flow through as a tool result, not a handler crash.
  - `terminate?` is a hint that the agent should stop after this
    turn. Honored by the loop but not mandatory.
  """

  @enforce_keys [:content]
  @type t :: %__MODULE__{
          content: [OctoPi.AI.Content.user_block()],
          details: term() | nil,
          is_error?: boolean(),
          terminate?: boolean()
        }

  defstruct [:content, details: nil, is_error?: false, terminate?: false]
end
