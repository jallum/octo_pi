defmodule OctoPi.Agent.Message do
  @moduledoc """
  The message union stored in a session's transcript.

  Four roles: user input, assistant replies, tool results (sent back
  to the model on the next turn), and app-defined custom messages
  that the model never sees. Matches pi-agent-core's `AgentMessage`
  union (see `tmp/pi-mono/packages/agent/src/types.ts` L255).

  User, Assistant, and ToolResult reuse the structs from
  `octo_pi_ai` — same shape, same invariants. A Custom message is
  an escape hatch for app-level annotations (system notes, fork
  markers) that flow through the event stream but are stripped
  before the LLM call.
  """

  alias OctoPi.Agent.Message.Custom
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  @type t :: User.t() | Assistant.t() | ToolResult.t() | Custom.t()
end
