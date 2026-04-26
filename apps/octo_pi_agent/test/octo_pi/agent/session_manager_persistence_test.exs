defmodule OctoPi.Agent.SessionManagerPersistenceTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.SessionEntry
  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionEntry.ModelChangeEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Content.Thinking
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp tmp_file do
    path = Path.join(System.tmp_dir!(), "session_#{:erlang.unique_integer([:positive])}.jsonl")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp user_msg(text), do: %User{content: text, timestamp: 0}

  defp assistant_msg(text) do
    %Assistant{
      api: :anthropic,
      provider: :anthropic,
      model: "claude-sonnet-4-6",
      timestamp: 0,
      content: [%Text{text: text}],
      stop_reason: :stop,
      usage: %Usage{input: 10, output: 5}
    }
  end

  defp tool_result_msg(id) do
    %ToolResult{
      tool_call_id: id,
      tool_name: "bash",
      content: [%Text{text: "ok"}],
      is_error?: false,
      timestamp: 0
    }
  end

  # ── Deferred write behavior ────────────────────────────────────────────────────

  describe "deferred first write" do
    test "no file created until first Assistant message" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("hello"))
      refute File.exists?(path)
      _sm = SessionManager.append_message(sm, assistant_msg("world"))
      assert File.exists?(path)
    end

    test "full buffer written on first Assistant message" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("hello"))
      _sm = SessionManager.append_message(sm, assistant_msg("world"))

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 2
    end

    test "subsequent entries appended as single lines" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("a"))
      sm = SessionManager.append_message(sm, assistant_msg("b"))
      sm = SessionManager.append_message(sm, user_msg("c"))
      _sm = SessionManager.append_message(sm, assistant_msg("d"))

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 4
    end

    test "no file at all if only user messages are appended" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("a"))
      _sm = SessionManager.append_message(sm, user_msg("b"))
      refute File.exists?(path)
    end
  end

  # ── Round-trip: new_from_file/1 ───────────────────────────────────────────────

  describe "new_from_file/1" do
    test "returns {:error, reason} for nonexistent file" do
      assert {:error, _reason} = SessionManager.new_from_file("/no/such/file.jsonl")
    end

    test "round-trips User and Assistant MessageEntry" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("hello"))
      _sm = SessionManager.append_message(sm, assistant_msg("world"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      assert length(loaded.entries) == 2

      [e1, e2] = loaded.entries
      assert %MessageEntry{message: %User{content: "hello"}} = e1
      assert %MessageEntry{message: %Assistant{content: [%Text{text: "world"}]}} = e2
    end

    test "round-trips ToolResult MessageEntry" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("run"))
      sm = SessionManager.append_message(sm, assistant_msg("ok"))
      _sm = SessionManager.append_message(sm, tool_result_msg("tc1"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      assert length(loaded.entries) == 3

      [_u, _a, tr] = loaded.entries
      assert %MessageEntry{message: %ToolResult{tool_call_id: "tc1", tool_name: "bash"}} = tr
    end

    test "round-trips Assistant with ToolCall content" do
      path = tmp_file()

      tool_call_msg = %Assistant{
        api: :anthropic,
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        timestamp: 0,
        content: [%ToolCall{id: "tc1", name: "bash", arguments: %{"cmd" => "ls"}}],
        stop_reason: :tool_use,
        usage: %Usage{}
      }

      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("run ls"))
      _sm = SessionManager.append_message(sm, tool_call_msg)

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      [_u, a] = loaded.entries
      assert %MessageEntry{message: %Assistant{content: [%ToolCall{id: "tc1", name: "bash"}]}} = a
    end

    test "round-trips CompactionEntry" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("a"))
      sm = SessionManager.append_message(sm, assistant_msg("b"))
      [u, _a] = sm.entries
      sm = SessionManager.append_compaction(sm, "Summary text", u.id, 500)
      _sm = SessionManager.append_message(sm, user_msg("c"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      compaction = Enum.find(loaded.entries, &match?(%CompactionEntry{}, &1))
      assert compaction.summary == "Summary text"
      assert compaction.tokens_before == 500
    end

    test "round-trips ModelChangeEntry" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("switch"))
      sm = SessionManager.append_message(sm, assistant_msg("ok"))

      sm =
        SessionManager.append(sm, %ModelChangeEntry{
          id: SessionEntry.generate_id(MapSet.new(Map.keys(sm.by_id))),
          parent_id: sm.leaf_id,
          timestamp: "t",
          provider: :anthropic,
          model_id: "claude-opus-4-7"
        })

      _sm = SessionManager.append_message(sm, user_msg("next"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      mc = Enum.find(loaded.entries, &match?(%ModelChangeEntry{}, &1))
      assert mc.provider == :anthropic
      assert mc.model_id == "claude-opus-4-7"
    end

    test "loaded session has correct leaf_id and by_id" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("a"))
      sm = SessionManager.append_message(sm, assistant_msg("b"))
      sm = SessionManager.append_message(sm, user_msg("c"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      assert loaded.leaf_id == sm.leaf_id
      assert map_size(loaded.by_id) == map_size(sm.by_id)
    end

    test "loaded session with session_file set can continue appending" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("a"))
      _sm = SessionManager.append_message(sm, assistant_msg("b"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      loaded = SessionManager.append_message(loaded, user_msg("c"))
      _loaded = SessionManager.append_message(loaded, assistant_msg("d"))

      lines = path |> File.read!() |> String.split("\n", trim: true)
      assert length(lines) == 4
    end

    test "Assistant message preserves api, provider, stop_reason" do
      path = tmp_file()
      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("hi"))
      _sm = SessionManager.append_message(sm, assistant_msg("hello"))

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      [_u, a] = loaded.entries
      assert %MessageEntry{message: %Assistant{api: :anthropic, provider: :anthropic, stop_reason: :stop}} = a
    end

    test "round-trips Assistant with Thinking content block" do
      path = tmp_file()

      thinking_msg = %Assistant{
        api: :anthropic,
        provider: :anthropic,
        model: "claude-sonnet-4-6",
        timestamp: 0,
        content: [%Thinking{thinking: "Let me think...", signature: "sig1"}, %Text{text: "Answer"}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      sm = SessionManager.new(session_file: path)
      sm = SessionManager.append_message(sm, user_msg("think"))
      _sm = SessionManager.append_message(sm, thinking_msg)

      assert {:ok, loaded} = SessionManager.new_from_file(path)
      [_u, a] = loaded.entries

      assert %MessageEntry{
               message: %Assistant{content: [%Thinking{thinking: "Let me think..."}, %Text{text: "Answer"}]}
             } = a
    end
  end

  # ── No session_file: no I/O ────────────────────────────────────────────────────

  describe "without session_file" do
    test "append_message works normally without any file I/O" do
      sm = SessionManager.new()
      sm = SessionManager.append_message(sm, user_msg("hello"))
      sm = SessionManager.append_message(sm, assistant_msg("world"))
      assert length(sm.entries) == 2
    end
  end
end
