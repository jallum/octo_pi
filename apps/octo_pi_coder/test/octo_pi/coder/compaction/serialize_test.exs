defmodule OctoPi.Coder.Compaction.SerializeTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Content.Thinking
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Serialize

  defp assistant(content) do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test",
      timestamp: 0,
      content: content,
      usage: %Usage{},
      stop_reason: :stop
    }
  end

  defp tool_result(text) do
    %ToolResult{
      tool_call_id: "tc1",
      tool_name: "read",
      content: [%Text{text: text}],
      is_error?: false,
      timestamp: 0
    }
  end

  describe "truncate_for_summary/2" do
    test "passes through text shorter than the budget" do
      assert Serialize.truncate_for_summary("hello", 2_000) == "hello"
    end

    test "passes through text exactly at the budget" do
      s = String.duplicate("x", 2_000)
      assert Serialize.truncate_for_summary(s, 2_000) == s
    end

    test "truncates with a marker reporting dropped grapheme count" do
      s = String.duplicate("x", 5_000)
      out = Serialize.truncate_for_summary(s, 2_000)
      assert String.starts_with?(out, String.duplicate("x", 2_000))
      assert out =~ "[... 3000 more characters truncated]"
      refute out =~ String.duplicate("x", 2_001)
    end

    test "is grapheme-safe — emoji boundaries are preserved" do
      # Without grapheme awareness a UTF-16 slice could split this.
      s = String.duplicate("🎉", 100)
      out = Serialize.truncate_for_summary(s, 50)
      kept = String.duplicate("🎉", 50)
      assert String.starts_with?(out, kept)
      assert out =~ "[... 50 more characters truncated]"
    end
  end

  describe "conversation/1 — user messages" do
    test "string content renders with the [User]: prefix" do
      msg = %User{content: "hi", timestamp: 0}
      assert Serialize.conversation([msg]) == "[User]: hi"
    end

    test "block content concatenates text blocks, ignoring others" do
      msg = %User{content: [%Text{text: "ab"}, %Text{text: "cd"}], timestamp: 0}
      assert Serialize.conversation([msg]) == "[User]: abcd"
    end

    test "user with empty content is dropped" do
      assert Serialize.conversation([%User{content: "", timestamp: 0}]) == ""
      assert Serialize.conversation([%User{content: [], timestamp: 0}]) == ""
    end
  end

  describe "conversation/1 — assistant messages" do
    test "thinking, text, and tool calls render in that fixed order" do
      msg =
        assistant([
          %Text{text: "answer"},
          %Thinking{thinking: "ponder"},
          %ToolCall{id: "1", name: "read", arguments: %{"path" => "f.ex"}}
        ])

      out = Serialize.conversation([msg])

      [thinking, text, calls] = String.split(out, "\n\n")
      assert thinking == "[Assistant thinking]: ponder"
      assert text == "[Assistant]: answer"
      assert calls == ~s|[Assistant tool calls]: read(path="f.ex")|
    end

    test "tool calls join multiple args with comma-space and JSON-encode values" do
      msg =
        assistant([
          %ToolCall{
            id: "1",
            name: "edit",
            arguments: %{"path" => "x.ex", "old" => "a", "new" => "b"}
          }
        ])

      out = Serialize.conversation([msg])
      # Map ordering isn't deterministic; assert each piece is present.
      assert out =~ ~r/\[Assistant tool calls\]: edit\(/
      assert out =~ ~s|path="x.ex"|
      assert out =~ ~s|old="a"|
      assert out =~ ~s|new="b"|
    end

    test "two tool calls are joined with '; '" do
      msg =
        assistant([
          %ToolCall{id: "1", name: "read", arguments: %{"path" => "a"}},
          %ToolCall{id: "2", name: "read", arguments: %{"path" => "b"}}
        ])

      out = Serialize.conversation([msg])
      assert out == ~s|[Assistant tool calls]: read(path="a"); read(path="b")|
    end

    test "assistant with only an empty content list contributes nothing" do
      assert Serialize.conversation([assistant([])]) == ""
    end
  end

  describe "conversation/1 — tool results" do
    test "short content renders verbatim with [Tool result]: prefix" do
      assert Serialize.conversation([tool_result("ok")]) == "[Tool result]: ok"
    end

    test "long tool result is truncated to 2000 chars (upstream parity)" do
      long = String.duplicate("x", 5_000)
      out = Serialize.conversation([tool_result(long)])
      assert String.starts_with?(out, "[Tool result]: " <> String.duplicate("x", 2_000))
      assert out =~ "[... 3000 more characters truncated]"
      refute out =~ String.duplicate("x", 3_000)
    end

    test "user and assistant messages are NOT truncated even if long" do
      long = String.duplicate("y", 5_000)

      msgs = [
        %User{content: long, timestamp: 0},
        assistant([%Text{text: long}])
      ]

      out = Serialize.conversation(msgs)
      refute out =~ "truncated"
      assert out =~ long
    end

    test "tool result with empty content is dropped" do
      empty = %ToolResult{
        tool_call_id: "1",
        tool_name: "read",
        content: [],
        is_error?: false,
        timestamp: 0
      }

      assert Serialize.conversation([empty]) == ""
    end
  end

  describe "conversation/1 — paragraphs and ordering" do
    test "messages are joined by a blank line" do
      msgs = [
        %User{content: "q", timestamp: 0},
        assistant([%Text{text: "a"}])
      ]

      assert Serialize.conversation(msgs) == "[User]: q\n\n[Assistant]: a"
    end

    test "unrecognized message types contribute nothing" do
      assert Serialize.conversation([%{role: :unknown}]) == ""
    end
  end
end
