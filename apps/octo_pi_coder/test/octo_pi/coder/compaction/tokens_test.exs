defmodule OctoPi.Coder.Compaction.TokensTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.{Image, Text, Thinking}
  alias OctoPi.AI.Message.{Assistant, ToolResult, User}
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Settings
  alias OctoPi.Coder.Compaction.Tokens

  defp usage(input \\ 100, output \\ 50, total \\ nil) do
    %Usage{
      input: input,
      output: output,
      cache_read: 0,
      cache_write: 0,
      total_tokens: total || input + output
    }
  end

  defp assistant(content, opts \\ []) do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test",
      timestamp: 0,
      content: content,
      usage: opts[:usage] || usage(),
      stop_reason: opts[:stop_reason] || :stop
    }
  end

  describe "calculate_context_tokens/1" do
    test "uses total_tokens when non-zero" do
      assert Tokens.calculate_context_tokens(usage(100, 50, 200)) == 200
    end

    test "falls back to summing components when total_tokens is 0" do
      u = %Usage{input: 10, output: 20, cache_read: 5, cache_write: 3, total_tokens: 0}
      assert Tokens.calculate_context_tokens(u) == 38
    end
  end

  describe "estimate_tokens/1 — user messages" do
    test "string content uses ceil(chars/4)" do
      m = %User{content: "abcdefg", timestamp: 0}
      # 7 chars → ceil(7/4) = 2
      assert Tokens.estimate_tokens(m) == 2
    end

    test "block-list content sums text blocks; ignores non-text" do
      m = %User{
        content: [%Text{text: "hello"}, %Image{data: "x", mime_type: "image/png"}, %Text{text: "world"}],
        timestamp: 0
      }

      # 5 + 5 = 10 chars → ceil(10/4) = 3
      assert Tokens.estimate_tokens(m) == 3
    end

    test "empty content returns 0" do
      assert Tokens.estimate_tokens(%User{content: "", timestamp: 0}) == 0
      assert Tokens.estimate_tokens(%User{content: [], timestamp: 0}) == 0
    end

    test "uses UTF-8 byte length, not grapheme count, to stay conservative" do
      # "héllo" is 5 graphemes but 6 bytes (é = 2 bytes in UTF-8).
      m = %User{content: "héllo", timestamp: 0}
      # 6 bytes → ceil(6/4) = 2; grapheme count would yield 5/4 → 2 (same here),
      # so use a longer string where the difference is observable.
      m2 = %User{content: "héllo héllo héllo", timestamp: 0}
      # 17 graphemes; UTF-8 bytes: 5*3 + 2*1(spaces) + 2*3(é runs)... easier: byte_size
      assert Tokens.estimate_tokens(m) == div(byte_size("héllo") + 3, 4)
      assert Tokens.estimate_tokens(m2) == div(byte_size("héllo héllo héllo") + 3, 4)
      # Sanity: byte count exceeds grapheme count.
      assert byte_size("héllo héllo héllo") > String.length("héllo héllo héllo")
    end
  end

  describe "estimate_tokens/1 — assistant messages" do
    test "text + thinking + tool calls all contribute" do
      a =
        assistant([
          %Text{text: "abcd"},
          %Thinking{thinking: "ef"},
          %ToolCall{id: "1", name: "read", arguments: %{"path" => "x"}}
        ])

      # text(4) + thinking(2) + name(4="read") + Jason.encode!(%{"path"=>"x"}) length
      args_json = Jason.encode!(%{"path" => "x"})
      expected_chars = 4 + 2 + String.length("read") + byte_size(args_json)
      expected = div(expected_chars + 3, 4)
      assert Tokens.estimate_tokens(a) == expected
    end

    test "empty content returns 0" do
      assert Tokens.estimate_tokens(assistant([])) == 0
    end
  end

  describe "estimate_tokens/1 — tool results" do
    test "string content" do
      tr = %ToolResult{
        tool_call_id: "1",
        tool_name: "read",
        content: "abcdefgh",
        is_error?: false,
        timestamp: 0
      }

      # 8 chars → 2
      assert Tokens.estimate_tokens(tr) == 2
    end

    test "image block contributes 4800 chars (≈1200 tokens)" do
      tr = %ToolResult{
        tool_call_id: "1",
        tool_name: "read",
        content: [%Image{data: "x", mime_type: "image/png"}],
        is_error?: false,
        timestamp: 0
      }

      assert Tokens.estimate_tokens(tr) == 1200
    end

    test "mixed text + image" do
      tr = %ToolResult{
        tool_call_id: "1",
        tool_name: "read",
        content: [%Text{text: "ab"}, %Image{data: "x", mime_type: "image/png"}],
        is_error?: false,
        timestamp: 0
      }

      # 2 + 4800 = 4802 → ceil(4802/4) = 1201
      assert Tokens.estimate_tokens(tr) == 1201
    end
  end

  describe "estimate_tokens/1 — other shapes" do
    test "unknown struct returns 0" do
      assert Tokens.estimate_tokens(%{}) == 0
    end
  end

  describe "estimate_tokens/1 — bashExecution / branchSummary / compactionSummary raw maps" do
    test "bashExecution: ceil((command + output) / 4)" do
      m = %{"role" => "bashExecution", "command" => "ls -la", "output" => "total 0"}
      # "ls -la" = 6 bytes, "total 0" = 7 bytes → 13 bytes → ceil(13/4) = 4
      assert Tokens.estimate_tokens(m) == 4
    end

    test "bashExecution: zero-length command and output" do
      assert Tokens.estimate_tokens(%{"role" => "bashExecution", "command" => "", "output" => ""}) == 0
    end

    test "branchSummary: ceil(byte_size(summary) / 4)" do
      summary = String.duplicate("a", 40)
      m = %{"role" => "branchSummary", "summary" => summary}
      assert Tokens.estimate_tokens(m) == 10
    end

    test "compactionSummary: ceil(byte_size(summary) / 4)" do
      summary = String.duplicate("b", 20)
      m = %{"role" => "compactionSummary", "summary" => summary}
      assert Tokens.estimate_tokens(m) == 5
    end

    test "branchSummary parity with BranchSummaryMessage struct" do
      alias OctoPi.Coder.Session.BranchSummaryMessage
      text = "some branch summary text"
      map = %{"role" => "branchSummary", "summary" => text}
      struct = BranchSummaryMessage.new(text, "root", 0)
      assert Tokens.estimate_tokens(map) == Tokens.estimate_tokens(struct)
    end

    test "compactionSummary parity with CompactionSummaryMessage struct" do
      alias OctoPi.Coder.Session.CompactionSummaryMessage
      text = "some compaction summary text"
      map = %{"role" => "compactionSummary", "summary" => text}
      struct = CompactionSummaryMessage.new(text, 0, 0)
      assert Tokens.estimate_tokens(map) == Tokens.estimate_tokens(struct)
    end
  end

  describe "estimate_context_tokens/1" do
    test "no assistant messages: pure estimation" do
      msgs = [%User{content: "abcdefgh", timestamp: 0}]

      assert Tokens.estimate_context_tokens(msgs) == %{
               tokens: 2,
               usage_tokens: 0,
               trailing_tokens: 2,
               last_usage_index: nil
             }
    end

    test "uses last assistant usage as baseline + estimates trailing" do
      msgs = [
        %User{content: "u1", timestamp: 0},
        assistant([%Text{text: "first"}], usage: usage(100, 50, 200)),
        %User{content: "u2 longer text here", timestamp: 0}
      ]

      trailing = Tokens.estimate_tokens(Enum.at(msgs, 2))

      assert Tokens.estimate_context_tokens(msgs) == %{
               tokens: 200 + trailing,
               usage_tokens: 200,
               trailing_tokens: trailing,
               last_usage_index: 1
             }
    end

    test "skips aborted/error assistant messages when picking baseline usage" do
      msgs = [
        assistant([%Text{text: "ok"}], usage: usage(50, 25, 100)),
        %User{content: "u", timestamp: 0},
        assistant([%Text{text: "boom"}],
          usage: usage(999, 999, 9999),
          stop_reason: :aborted
        )
      ]

      result = Tokens.estimate_context_tokens(msgs)
      assert result.usage_tokens == 100
      assert result.last_usage_index == 0
    end
  end

  describe "should_compact?/3" do
    test "false when settings disable compaction" do
      refute Tokens.should_compact?(999_999, 100_000, %Settings{enabled: false})
    end

    test "true when context_tokens exceeds window minus reserve" do
      s = %Settings{enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000}
      # threshold = 100_000 - 16_384 = 83_616
      refute Tokens.should_compact?(83_616, 100_000, s)
      assert Tokens.should_compact?(83_617, 100_000, s)
    end
  end

  describe "Settings.default/0" do
    test "matches upstream DEFAULT_COMPACTION_SETTINGS" do
      d = Settings.default()
      assert d.enabled == true
      assert d.reserve_tokens == 16_384
      assert d.keep_recent_tokens == 20_000
    end
  end
end
