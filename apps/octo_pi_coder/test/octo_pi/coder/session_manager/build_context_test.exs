defmodule OctoPi.Coder.SessionManager.BuildContextTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager

  # ---- helpers — port of build-context.test.ts msg/compaction/branchSummary/etc.

  defp msg(id, parent, role, text) do
    base = %Entry.Message{id: id, parent_id: parent, timestamp: "2025-01-01T00:00:00Z", message: nil}

    case role do
      :user -> %{base | message: %{"role" => "user", "content" => text, "timestamp" => 1}}
      :assistant ->
        %{
          base
          | message: %{
              "role" => "assistant",
              "content" => [%{"type" => "text", "text" => text}],
              "provider" => "anthropic",
              "model" => "claude-test"
            }
        }
    end
  end

  defp compaction(id, parent, summary, first_kept) do
    %Entry.Compaction{
      id: id,
      parent_id: parent,
      timestamp: "2025-01-01T00:00:00Z",
      summary: summary,
      first_kept_entry_id: first_kept,
      tokens_before: 1000
    }
  end

  defp branch_summary(id, parent, summary, from_id) do
    %Entry.BranchSummary{
      id: id,
      parent_id: parent,
      timestamp: "2025-01-01T00:00:00Z",
      summary: summary,
      from_id: from_id
    }
  end

  defp thinking(id, parent, level) do
    %Entry.ThinkingLevelChange{
      id: id,
      parent_id: parent,
      timestamp: "2025-01-01T00:00:00Z",
      thinking_level: level
    }
  end

  defp model_change(id, parent, provider, model_id) do
    %Entry.ModelChange{
      id: id,
      parent_id: parent,
      timestamp: "2025-01-01T00:00:00Z",
      provider: provider,
      model_id: model_id
    }
  end

  defp sm(entries) do
    by_id = Map.new(entries, fn e -> {e.id, e} end)
    leaf_id = entries |> List.last() |> case do
      nil -> nil
      e -> e.id
    end

    %SessionManager{
      cwd: "/c",
      session_id: "s",
      version: 3,
      file_entries: entries,
      by_id: by_id,
      leaf_id: leaf_id
    }
  end

  defp ctx(entries, leaf_id \\ :default) do
    SessionManager.build_session_context(sm(entries), leaf_id)
  end

  # ---- trivial cases ----

  describe "trivial cases" do
    test "empty entries returns empty context" do
      c = ctx([])
      assert c.messages == []
      assert c.thinking_level == "off"
      assert c.model == nil
    end

    test "single user message" do
      c = ctx([msg("1", nil, :user, "hello")])
      assert length(c.messages) == 1
      assert hd(c.messages)["role"] == "user"
    end

    test "simple conversation — message order preserved" do
      c =
        ctx([
          msg("1", nil, :user, "hello"),
          msg("2", "1", :assistant, "hi there"),
          msg("3", "2", :user, "how are you"),
          msg("4", "3", :assistant, "great")
        ])

      assert length(c.messages) == 4
      assert Enum.map(c.messages, & &1["role"]) == ["user", "assistant", "user", "assistant"]
    end

    test "tracks thinking level changes" do
      c =
        ctx([
          msg("1", nil, :user, "hello"),
          thinking("2", "1", "high"),
          msg("3", "2", :assistant, "thinking hard")
        ])

      assert c.thinking_level == "high"
      assert length(c.messages) == 2
    end

    test "tracks model from assistant message" do
      c = ctx([msg("1", nil, :user, "hi"), msg("2", "1", :assistant, "hi back")])
      assert c.model == %{provider: "anthropic", model_id: "claude-test"}
    end

    test "assistant model overrides preceding model_change" do
      c =
        ctx([
          msg("1", nil, :user, "hi"),
          model_change("2", "1", "openai", "gpt-4"),
          msg("3", "2", :assistant, "hi back")
        ])

      assert c.model == %{provider: "anthropic", model_id: "claude-test"}
    end
  end

  # ---- compaction ----

  describe "with compaction" do
    test "places synthetic summary before kept window" do
      c =
        ctx([
          msg("1", nil, :user, "first"),
          msg("2", "1", :assistant, "response1"),
          msg("3", "2", :user, "second"),
          msg("4", "3", :assistant, "response2"),
          compaction("5", "4", "Summary of first two turns", "3"),
          msg("6", "5", :user, "third"),
          msg("7", "6", :assistant, "response3")
        ])

      # synthetic + kept(3,4) + after(6,7) = 5 messages
      assert length(c.messages) == 5
      [first | rest] = c.messages
      assert %CompactionSummaryMessage{summary: s} = first
      assert s =~ "Summary of first two turns"
      assert Enum.at(rest, 0)["content"] == "second"
      assert Enum.at(rest, 1)["content"] |> hd() |> Map.get("text") == "response2"
      assert Enum.at(rest, 2)["content"] == "third"
      assert Enum.at(rest, 3)["content"] |> hd() |> Map.get("text") == "response3"
    end

    test "compaction keeping from first message" do
      c =
        ctx([
          msg("1", nil, :user, "first"),
          msg("2", "1", :assistant, "response"),
          compaction("3", "2", "Empty summary", "1"),
          msg("4", "3", :user, "second")
        ])

      # summary + (1, 2, 4) = 4
      assert length(c.messages) == 4
      [%CompactionSummaryMessage{summary: s} | _] = c.messages
      assert s =~ "Empty summary"
    end

    test "multiple compactions — latest wins" do
      c =
        ctx([
          msg("1", nil, :user, "a"),
          msg("2", "1", :assistant, "b"),
          compaction("3", "2", "First summary", "1"),
          msg("4", "3", :user, "c"),
          msg("5", "4", :assistant, "d"),
          compaction("6", "5", "Second summary", "4"),
          msg("7", "6", :user, "e")
        ])

      assert length(c.messages) == 4
      [%CompactionSummaryMessage{summary: s} | _] = c.messages
      assert s =~ "Second summary"
    end
  end

  # ---- branches ----

  describe "with branches" do
    test "follows path to specified leaf" do
      entries = [
        msg("1", nil, :user, "start"),
        msg("2", "1", :assistant, "response"),
        msg("3", "2", :user, "branch A"),
        msg("4", "2", :user, "branch B")
      ]

      a = ctx(entries, "3")
      assert length(a.messages) == 3
      assert Enum.at(a.messages, 2)["content"] == "branch A"

      b = ctx(entries, "4")
      assert length(b.messages) == 3
      assert Enum.at(b.messages, 2)["content"] == "branch B"
    end

    test "branch summary becomes a synthetic message in path" do
      entries = [
        msg("1", nil, :user, "start"),
        msg("2", "1", :assistant, "response"),
        msg("3", "2", :user, "abandoned path"),
        branch_summary("4", "2", "Summary of abandoned work", "3"),
        msg("5", "4", :user, "new direction")
      ]

      c = ctx(entries, "5")
      assert length(c.messages) == 4
      assert %BranchSummaryMessage{summary: s} = Enum.at(c.messages, 2)
      assert s =~ "Summary of abandoned work"
      assert Enum.at(c.messages, 3)["content"] == "new direction"
    end

    test "complex tree with compaction on main path and branch summary on side path" do
      entries = [
        msg("1", nil, :user, "start"),
        msg("2", "1", :assistant, "r1"),
        msg("3", "2", :user, "q2"),
        msg("4", "3", :assistant, "r2"),
        compaction("5", "4", "Compacted history", "3"),
        msg("6", "5", :user, "q3"),
        msg("7", "6", :assistant, "r3"),
        msg("8", "3", :user, "wrong path"),
        msg("9", "8", :assistant, "wrong response"),
        branch_summary("10", "3", "Tried wrong approach", "9"),
        msg("11", "10", :user, "better approach")
      ]

      main = ctx(entries, "7")
      assert length(main.messages) == 5
      assert %CompactionSummaryMessage{summary: ms} = Enum.at(main.messages, 0)
      assert ms =~ "Compacted history"
      assert Enum.at(main.messages, 1)["content"] == "q2"
      assert Enum.at(main.messages, 2)["content"] |> hd() |> Map.get("text") == "r2"
      assert Enum.at(main.messages, 3)["content"] == "q3"
      assert Enum.at(main.messages, 4)["content"] |> hd() |> Map.get("text") == "r3"

      branch = ctx(entries, "11")
      assert length(branch.messages) == 5
      assert Enum.at(branch.messages, 0)["content"] == "start"
      assert Enum.at(branch.messages, 1)["content"] |> hd() |> Map.get("text") == "r1"
      assert Enum.at(branch.messages, 2)["content"] == "q2"
      assert %BranchSummaryMessage{summary: bs} = Enum.at(branch.messages, 3)
      assert bs =~ "Tried wrong approach"
      assert Enum.at(branch.messages, 4)["content"] == "better approach"
    end
  end

  # ---- edge cases ----

  describe "edge cases" do
    test "uses last entry when leafId not found" do
      c =
        ctx(
          [msg("1", nil, :user, "hello"), msg("2", "1", :assistant, "hi")],
          "nonexistent"
        )

      assert length(c.messages) == 2
    end

    test "orphaned entries — chain terminates at the orphan" do
      entries = [msg("1", nil, :user, "hello"), msg("2", "missing", :assistant, "orphan")]
      c = ctx(entries, "2")
      assert length(c.messages) == 1
    end

    test "explicit nil leaf returns empty context" do
      c = ctx([msg("1", nil, :user, "x")], nil)
      assert c.messages == []
      assert c.thinking_level == "off"
      assert c.model == nil
    end
  end
end
