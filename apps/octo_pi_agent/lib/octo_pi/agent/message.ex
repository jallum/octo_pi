defmodule OctoPi.Agent.Message do
  @moduledoc """
  The message union stored in a session's transcript.

  Three LLM-relevant roles: user input, assistant replies, and tool
  results (sent back to the model on the next turn). Matches
  pi-agent-core's `AgentMessage` union (see
  `tmp/pi-mono/packages/agent/src/types.ts` L255).

  Each member reuses the struct from `octo_pi_ai` — same shape, same
  invariants.

  Extension state that needs to survive a session reload but stay
  invisible to the LLM lives outside this union, persisted as a
  `OctoPi.Coder.Session.Entry.Custom` in the entry stream (the right
  architectural home — matches upstream `CustomEntry`).
  """

  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  @type t :: User.t() | Assistant.t() | ToolResult.t()
end
