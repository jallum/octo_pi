defmodule OctoPi.Coder.Session.Messages do
  @moduledoc """
  Convert the synthetic messages produced by
  `SessionManager.build_session_context/2` into LLM-compatible
  `%OctoPi.AI.Message.User{}` blocks. Port of `convertToLlm`
  (`tmp/pi-mono/.../core/messages.ts:148-196`).

  Synthetic roles never reach a provider in upstream — the conversion
  happens at the agent-loop boundary
  (`tmp/pi-mono/.../packages/agent/src/agent-loop.ts:240-254`). This
  module is the equivalent boundary for our coder loop (wired in by
  `opi-ixp.24` / E5a).

  Currently handles:

  - `CompactionSummaryMessage` → user text wrapped with
    `COMPACTION_SUMMARY_PREFIX/SUFFIX`.
  - `BranchSummaryMessage` → user text wrapped with
    `BRANCH_SUMMARY_PREFIX/SUFFIX`.

  `User`, `Assistant`, `ToolResult` pass through. New synthetic types
  (e.g. `BashExecutionMessage`, `Custom`) get heads added here as they
  land — same single-point-of-extension design as upstream.
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.User
  alias OctoPi.Coder.Session.{BranchSummaryMessage, CompactionSummaryMessage}

  # Verbatim from `messages.ts:13-27`.
  @compaction_prefix "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
  @compaction_suffix "\n</summary>"
  @branch_prefix "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
  @branch_suffix "</summary>"

  @spec to_llm([term()]) :: [term()]
  def to_llm(messages) when is_list(messages), do: Enum.map(messages, &convert/1)

  defp convert(%CompactionSummaryMessage{summary: s, timestamp: ts}),
    do: wrap_user(@compaction_prefix <> s <> @compaction_suffix, ts)

  defp convert(%BranchSummaryMessage{summary: s, timestamp: ts}),
    do: wrap_user(@branch_prefix <> s <> @branch_suffix, ts)

  defp convert(other), do: other

  defp wrap_user(text, timestamp) do
    %User{content: [%Text{text: text}], timestamp: timestamp}
  end
end
