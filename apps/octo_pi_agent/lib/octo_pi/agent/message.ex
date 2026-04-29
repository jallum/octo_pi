defmodule OctoPi.Agent.Message do
  @moduledoc """
  The message union stored in a loop's transcript.

  Three LLM-relevant roles: user input, assistant replies, and tool
  results (sent back to the model on the next turn). Matches
  pi-agent-core's `AgentMessage` union (see
  `tmp/pi-mono/packages/agent/src/types.ts` L255).

  Each member reuses the struct from `octo_pi_ai` — same shape, same
  invariants.

  Extension state that needs to survive a loop reload but stay
  invisible to the LLM lives outside this union, persisted as a
  `OctoPi.Coder.Session.Entry.Custom` in the entry stream (the right
  architectural home — matches upstream `CustomEntry`).
  """

  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @spec normalize(String.t() | t() | [String.t() | t()]) :: t() | [t()]
  def normalize(msgs) when is_list(msgs), do: Enum.map(msgs, &normalize/1)
  def normalize(str) when is_binary(str), do: %User{content: str, timestamp: :os.system_time(:millisecond)}
  def normalize(%User{} = m), do: m
  def normalize(%Assistant{} = m), do: m
  def normalize(%ToolResult{} = m), do: m
  def normalize(invalid), do: raise(ArgumentError, "Expected Message.t() or String.t(), got: #{inspect(invalid)}")

  @spec role(t()) :: :user | :assistant | :tool_result
  def role(%User{}), do: :user
  def role(%Assistant{}), do: :assistant
  def role(%ToolResult{}), do: :tool_result

  @spec convert_to_llm([t()]) :: [t()]
  def convert_to_llm(messages), do: messages
end
