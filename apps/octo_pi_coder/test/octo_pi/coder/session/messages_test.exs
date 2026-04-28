defmodule OctoPi.Coder.Session.MessagesTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Messages

  @compaction_prefix "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
  @compaction_suffix "\n</summary>"
  @branch_prefix "The following is a summary of a branch that this conversation came back from:\n\n<summary>\n"
  @branch_suffix "</summary>"

  describe "to_llm/1" do
    test "empty list passes through" do
      assert Messages.to_llm([]) == []
    end

    test "User / Assistant / ToolResult pass through unchanged" do
      msgs = [
        %User{content: "hi", timestamp: 1},
        %Assistant{
          api: :anthropic_messages,
          provider: :anthropic,
          model: "m",
          timestamp: 2,
          stop_reason: :stop,
          content: [%Text{text: "ok"}],
          usage: %Usage{}
        },
        %ToolResult{
          tool_call_id: "tc-1",
          tool_name: "read",
          content: [%Text{text: "x"}],
          is_error?: false,
          timestamp: 3
        }
      ]

      assert Messages.to_llm(msgs) == msgs
    end

    test "compactionSummary becomes a user message wrapped with the upstream prefix/suffix" do
      msg = CompactionSummaryMessage.new("BODY", 999, 12_345)

      assert [%User{content: [%Text{text: text}], timestamp: ts}] = Messages.to_llm([msg])
      assert text == @compaction_prefix <> "BODY" <> @compaction_suffix
      assert ts == msg.timestamp
    end

    test "branchSummary becomes a user message wrapped with the upstream prefix/suffix" do
      msg = BranchSummaryMessage.new("BRANCH-BODY", "from-id", 67_890)

      assert [%User{content: [%Text{text: text}], timestamp: ts}] = Messages.to_llm([msg])
      assert text == @branch_prefix <> "BRANCH-BODY" <> @branch_suffix
      assert ts == msg.timestamp
    end

    test "preserves message ordering across mixed roles" do
      u = %User{content: "u1", timestamp: 1}
      c = CompactionSummaryMessage.new("C", 0, 2)

      a = %Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "m",
        timestamp: 3,
        stop_reason: :stop,
        content: [%Text{text: "a1"}],
        usage: %Usage{}
      }

      b = BranchSummaryMessage.new("B", "from", 4)

      result = Messages.to_llm([u, c, a, b])

      assert [^u, %User{content: [%Text{text: ct}]}, ^a, %User{content: [%Text{text: bt}]}] = result
      assert ct =~ "<summary>\nC\n</summary>"
      assert bt =~ "<summary>\nB</summary>"
    end
  end
end
