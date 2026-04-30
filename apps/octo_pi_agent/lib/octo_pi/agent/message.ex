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

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  @type t :: User.t() | Assistant.t() | ToolResult.t()

  @doc """
  Normalize a single value or list into the canonical `t()` shape.

  Lifts string content into `[%OctoPi.AI.Content.Text{text: bin}]` so
  every `User.t()` / `ToolResult.t()` returned has list-shape content.
  This is the construction-time canonicalization that lets every
  downstream consumer assume a single shape (see opi-5ka).

    * `binary` -> `%User{content: [%Text{text: binary}], timestamp: now}`
    * `%User{content: binary}` -> lifted to `[%Text{text: binary}]`
    * `%User{content: list}` -> passed through
    * `%ToolResult{content: binary}` -> lifted to `[%Text{text: binary}]`
    * `%ToolResult{content: list}` -> passed through
    * `%Assistant{}` -> passed through (already list-shape by type)
  """
  @spec normalize(String.t() | t() | [String.t() | t()]) :: t() | [t()]
  def normalize(msgs) when is_list(msgs), do: Enum.map(msgs, &normalize/1)

  def normalize(str) when is_binary(str),
    do: %User{content: [%Text{text: str}], timestamp: :os.system_time(:millisecond)}

  def normalize(%User{content: c} = m) when is_binary(c), do: %{m | content: [%Text{text: c}]}
  def normalize(%User{content: c} = m) when is_list(c), do: m

  def normalize(%Assistant{} = m), do: m

  def normalize(%ToolResult{content: c} = m) when is_binary(c), do: %{m | content: [%Text{text: c}]}
  def normalize(%ToolResult{content: c} = m) when is_list(c), do: m

  def normalize(invalid), do: raise(ArgumentError, "Expected Message.t() or String.t(), got: #{inspect(invalid)}")

  @spec role(t()) :: :user | :assistant | :tool_result
  def role(%User{}), do: :user
  def role(%Assistant{}), do: :assistant
  def role(%ToolResult{}), do: :tool_result
end
