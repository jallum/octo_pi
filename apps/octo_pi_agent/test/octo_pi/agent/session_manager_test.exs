defmodule OctoPi.Agent.SessionManagerTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionEntry.CustomEntry
  alias OctoPi.Agent.SessionEntry.CustomMessageEntry
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionEntry.ModelChangeEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User

  defp user_msg(text), do: %User{content: text, timestamp: 0}

  defp assistant_msg(text),
    do: %Assistant{
      content: [%Text{text: text}],
      api: :anthropic,
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      timestamp: 0,
      stop_reason: :stop,
      usage: %OctoPi.AI.Usage{input: 10, output: 5}
    }

  defp tool_result_msg(id),
    do: %ToolResult{tool_call_id: id, tool_name: "bash", content: [%Text{text: "ok"}], is_error?: false, timestamp: 0}

  describe "new/0 and new/1" do
    test "new/0 creates an empty manager" do
      sm = SessionManager.new()
      assert sm.entries == []
      assert sm.by_id == %{}
      assert sm.leaf_id == nil
    end

    test "new/1 with initial_entries rebuilds by_id and leaf_id" do
      sm0 = SessionManager.new()
      sm1 = SessionManager.append_message(sm0, user_msg("hello"))
      sm2 = SessionManager.append_message(sm1, assistant_msg("hi"))

      # Reconstruct from the entries list
      sm_reloaded = SessionManager.new(initial_entries: sm2.entries)
      assert sm_reloaded.leaf_id == sm2.leaf_id
      assert map_size(sm_reloaded.by_id) == 2
      assert length(sm_reloaded.entries) == 2
    end

    test "new/1 with empty initial_entries returns empty manager" do
      sm = SessionManager.new(initial_entries: [])
      assert sm.leaf_id == nil
      assert sm.entries == []
    end
  end

  describe "append_message/2" do
    test "appends a MessageEntry and advances leaf_id" do
      sm = SessionManager.new()
      sm1 = SessionManager.append_message(sm, user_msg("hello"))

      assert length(sm1.entries) == 1
      [entry] = sm1.entries
      assert %MessageEntry{} = entry
      assert entry.message == user_msg("hello")
      assert entry.parent_id == nil
      assert entry.id == sm1.leaf_id
    end

    test "each append sets parent_id to the previous leaf" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))
        |> SessionManager.append_message(user_msg("c"))

      [e1, e2, e3] = sm.entries
      assert e1.parent_id == nil
      assert e2.parent_id == e1.id
      assert e3.parent_id == e2.id
      assert sm.leaf_id == e3.id
    end

    test "entries are stored in by_id map" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))

      [e1, e2] = sm.entries
      assert sm.by_id[e1.id] == e1
      assert sm.by_id[e2.id] == e2
    end
  end

  describe "append_compaction/4" do
    test "appends a CompactionEntry" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))

      [e1, _e2] = sm.entries
      sm2 = SessionManager.append_compaction(sm, "Summary text", e1.id, 1000)

      assert length(sm2.entries) == 3
      compaction = List.last(sm2.entries)
      assert %CompactionEntry{} = compaction
      assert compaction.summary == "Summary text"
      assert compaction.first_kept_entry_id == e1.id
      assert compaction.tokens_before == 1000
      assert compaction.from_hook? == false
    end

    test "accepts opts: details and from_hook" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))
      [e1] = sm.entries

      sm2 =
        SessionManager.append_compaction(sm, "s", e1.id, 500,
          details: %{custom: true},
          from_hook: true
        )

      compaction = List.last(sm2.entries)
      assert compaction.details == %{custom: true}
      assert compaction.from_hook? == true
    end
  end

  describe "append_custom_entry/3" do
    test "appends a CustomEntry (not sent to LLM)" do
      sm = SessionManager.append_custom_entry(SessionManager.new(), "my_ext", %{key: "val"})

      [entry] = sm.entries
      assert %CustomEntry{} = entry
      assert entry.custom_type == "my_ext"
      assert entry.data == %{key: "val"}
    end

    test "data defaults to nil" do
      sm = SessionManager.append_custom_entry(SessionManager.new(), "ext")
      [entry] = sm.entries
      assert entry.data == nil
    end
  end

  describe "append_custom_message_entry/4" do
    test "appends a CustomMessageEntry" do
      sm = SessionManager.append_custom_message_entry(SessionManager.new(), "ext", "hello", display: true)

      [entry] = sm.entries
      assert %CustomMessageEntry{} = entry
      assert entry.custom_type == "ext"
      assert entry.content == "hello"
      assert entry.display == true
    end

    test "display defaults to false" do
      sm = SessionManager.append_custom_message_entry(SessionManager.new(), "ext", "hi")
      [entry] = sm.entries
      assert entry.display == false
    end
  end

  describe "append_label/3" do
    test "appends a LabelEntry pointing to another entry" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))

      [target] = sm.entries
      sm2 = SessionManager.append_label(sm, target.id, "my label")

      assert length(sm2.entries) == 2
      label_entry = List.last(sm2.entries)
      assert label_entry.entry_id == target.id
      assert label_entry.label == "my label"
    end

    test "label can be nil to remove a label" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))
      [target] = sm.entries
      sm2 = SessionManager.append_label(sm, target.id, nil)
      label_entry = List.last(sm2.entries)
      assert label_entry.label == nil
    end
  end

  describe "get_branch/1 and get_branch/2" do
    test "returns empty list for empty manager" do
      assert SessionManager.get_branch(SessionManager.new()) == []
    end

    test "returns all entries oldest-first for a linear chain" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))
        |> SessionManager.append_message(user_msg("c"))

      branch = SessionManager.get_branch(sm)
      assert length(branch) == 3
      [e1, e2, e3] = sm.entries
      assert branch == [e1, e2, e3]
    end

    test "get_branch/2 returns path to a specific entry" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))
        |> SessionManager.append_message(user_msg("c"))

      [e1, e2, _e3] = sm.entries
      branch = SessionManager.get_branch(sm, e2.id)
      assert branch == [e1, e2]
    end

    test "returns single entry for root node" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))
      [e1] = sm.entries
      assert SessionManager.get_branch(sm) == [e1]
    end
  end

  describe "get_latest_compaction_entry/1" do
    test "returns nil when no compaction entries" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("a"))
        |> SessionManager.append_message(assistant_msg("b"))

      assert SessionManager.get_latest_compaction_entry(sm) == nil
    end

    test "returns the latest CompactionEntry" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))
      [e1] = sm.entries
      sm2 = SessionManager.append_compaction(sm, "first", e1.id, 100)
      sm3 = SessionManager.append_message(sm2, user_msg("b"))
      [e1b] = sm3.entries |> Enum.filter(&match?(%MessageEntry{}, &1)) |> Enum.take(-1)
      sm4 = SessionManager.append_compaction(sm3, "second", e1b.id, 200)

      result = SessionManager.get_latest_compaction_entry(sm4)
      assert %CompactionEntry{} = result
      assert result.summary == "second"
    end

    test "returns the single compaction when only one exists" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("a"))
      [e1] = sm.entries
      sm2 = SessionManager.append_compaction(sm, "only one", e1.id, 100)

      result = SessionManager.get_latest_compaction_entry(sm2)
      assert result.summary == "only one"
    end
  end

  describe "build_session_context/1" do
    test "includes all messages when no compaction" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("1"))
        |> SessionManager.append_message(assistant_msg("a"))
        |> SessionManager.append_message(user_msg("2"))
        |> SessionManager.append_message(assistant_msg("b"))

      ctx = SessionManager.build_session_context(sm)
      assert length(ctx.messages) == 4
    end

    test "handles single compaction: summary first, then kept messages" do
      sm0 = SessionManager.new()
      sm1 = SessionManager.append_message(sm0, user_msg("1"))
      sm2 = SessionManager.append_message(sm1, assistant_msg("a"))
      sm3 = SessionManager.append_message(sm2, user_msg("2"))
      sm4 = SessionManager.append_message(sm3, assistant_msg("b"))

      [_u1, _a1, u2, _a2] = sm4.entries

      # Compact: keep from u2 onwards
      sm5 = SessionManager.append_compaction(sm4, "Summary of 1,a", u2.id, 1000)
      sm6 = SessionManager.append_message(sm5, user_msg("3"))
      sm7 = SessionManager.append_message(sm6, assistant_msg("c"))

      ctx = SessionManager.build_session_context(sm7)
      # summary + kept (u2, a2) + after (u3, a3) = 5
      assert length(ctx.messages) == 5
      assert %User{content: "Summary of 1,a"} = hd(ctx.messages)
    end

    test "only the latest compaction matters" do
      sm0 = SessionManager.new()
      sm1 = SessionManager.append_message(sm0, user_msg("1"))
      sm2 = SessionManager.append_message(sm1, assistant_msg("a"))
      [u1, _a1] = sm2.entries
      sm3 = SessionManager.append_compaction(sm2, "First summary", u1.id, 500)

      sm4 = SessionManager.append_message(sm3, user_msg("2"))
      sm5 = SessionManager.append_message(sm4, assistant_msg("b"))
      sm6 = SessionManager.append_message(sm5, user_msg("3"))
      # Capture the u3 entry id immediately after appending it
      u3_id = sm6.leaf_id
      sm7 = SessionManager.append_message(sm6, assistant_msg("c"))

      sm8 = SessionManager.append_compaction(sm7, "Second summary", u3_id, 800)

      sm9 = SessionManager.append_message(sm8, user_msg("4"))
      sm10 = SessionManager.append_message(sm9, assistant_msg("d"))

      ctx = SessionManager.build_session_context(sm10)
      # summary + kept from u3 (u3, c) + after (u4, d) = 5
      assert length(ctx.messages) == 5
      assert %User{content: "Second summary"} = hd(ctx.messages)
    end

    test "when first_kept_entry_id is the first entry, all messages are included" do
      sm0 = SessionManager.new()
      sm1 = SessionManager.append_message(sm0, user_msg("1"))
      sm2 = SessionManager.append_message(sm1, assistant_msg("a"))
      [u1, _a1] = sm2.entries

      sm3 = SessionManager.append_compaction(sm2, "Summary", u1.id, 100)
      sm4 = SessionManager.append_message(sm3, user_msg("2"))
      sm5 = SessionManager.append_message(sm4, assistant_msg("b"))

      ctx = SessionManager.build_session_context(sm5)
      # summary + all messages (u1, a1, u2, b) = 5
      assert length(ctx.messages) == 5
    end

    test "CustomMessageEntry is included in context" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("hi"))
        |> SessionManager.append_custom_message_entry("ext", "injected message")

      ctx = SessionManager.build_session_context(sm)
      assert length(ctx.messages) == 2
      assert Enum.any?(ctx.messages, &match?(%User{content: "injected message"}, &1))
    end

    test "CustomEntry is NOT included in context" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("hi"))
        |> SessionManager.append_custom_entry("ext", %{state: true})

      ctx = SessionManager.build_session_context(sm)
      assert length(ctx.messages) == 1
    end

    test "returns nil model and :off thinking_level when no model change entries" do
      sm = SessionManager.append_message(SessionManager.new(), user_msg("hi"))
      ctx = SessionManager.build_session_context(sm)
      assert ctx.model == nil
      assert ctx.thinking_level == :off
    end

    test "returns model from latest ModelChangeEntry" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("hi"))
        |> SessionManager.append(%ModelChangeEntry{
          id: "aabbccdd",
          parent_id: nil,
          timestamp: "t",
          provider: :anthropic,
          model_id: "claude-opus-4-7"
        })

      ctx = SessionManager.build_session_context(sm)
      assert ctx.model == %{provider: :anthropic, model_id: "claude-opus-4-7"}
    end

    test "empty manager returns empty messages" do
      ctx = SessionManager.build_session_context(SessionManager.new())
      assert ctx.messages == []
      assert ctx.model == nil
      assert ctx.thinking_level == :off
    end

    test "tool_result message is included in context" do
      sm =
        SessionManager.new()
        |> SessionManager.append_message(user_msg("run bash"))
        |> SessionManager.append_message(assistant_msg("ok"))
        |> SessionManager.append_message(tool_result_msg("tc1"))

      ctx = SessionManager.build_session_context(sm)
      assert length(ctx.messages) == 3
      assert Enum.any?(ctx.messages, &match?(%ToolResult{}, &1))
    end
  end
end
