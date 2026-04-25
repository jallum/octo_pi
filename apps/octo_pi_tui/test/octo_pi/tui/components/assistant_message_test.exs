defmodule OctoPi.TUI.Components.AssistantMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  # ── Basic rendering ─────────────────────────────────────────────

  describe "render/2" do
    test "renders empty content as empty list" do
      msg = AssistantMessage.new(@theme)
      assert AssistantMessage.render(msg, 80) == []
    end

    test "renders text content as markdown" do
      msg = AssistantMessage.new(@theme, content: [{:text, "**hello** world"}])
      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "hello"))
      assert Enum.any?(stripped, &(&1 =~ "world"))
    end

    test "renders multiple text blocks" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:text, "first"}, {:text, "second"}]
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "first"))
      assert Enum.any?(stripped, &(&1 =~ "second"))
    end

    test "skips empty text blocks" do
      msg = AssistantMessage.new(@theme, content: [{:text, ""}, {:text, "real"}])
      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "real"))
    end
  end

  # ── Thinking blocks ─────────────────────────────────────────────

  describe "thinking blocks" do
    test "renders thinking content when not hidden" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:thinking, "let me think..."}],
          hide_thinking: false
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "let me think"))
    end

    test "shows label when thinking is hidden" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:thinking, "deep thought"}],
          hide_thinking: true
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Thinking..."))
      refute Enum.any?(stripped, &(&1 =~ "deep thought"))
    end

    test "custom hidden thinking label" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:thinking, "x"}],
          hide_thinking: true,
          hidden_thinking_label: "Processing..."
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Processing..."))
    end

    test "thinking content uses italic styling" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:thinking, "reasoning"}],
          hide_thinking: false
        )

      lines = AssistantMessage.render(msg, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[3m"))
    end
  end

  # ── Error/abort states ──────────────────────────────────────────

  describe "error and abort states" do
    test "renders abort message" do
      msg = AssistantMessage.new(@theme, stop_reason: :aborted)
      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Operation aborted"))
    end

    test "renders custom abort message" do
      msg =
        AssistantMessage.new(@theme,
          stop_reason: :aborted,
          error_message: "Cancelled by user"
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Cancelled by user"))
    end

    test "renders error message" do
      msg =
        AssistantMessage.new(@theme,
          stop_reason: :error,
          error_message: "API timeout"
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Error: API timeout"))
    end

    test "renders generic error when no message" do
      msg = AssistantMessage.new(@theme, stop_reason: :error)
      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Unknown error"))
    end

    test "normal completion (:stop) renders without status line" do
      msg =
        AssistantMessage.new(@theme,
          stop_reason: :stop,
          content: [text: "done"]
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      refute Enum.any?(stripped, &(&1 =~ "error" or &1 =~ "abort"))
    end

    test "max_tokens (:length) renders without crash" do
      msg =
        AssistantMessage.new(@theme,
          stop_reason: :length,
          content: [text: "partial output"]
        )

      lines = AssistantMessage.render(msg, 80)
      assert is_list(lines)
    end

    test "suppresses error display when has_tool_calls" do
      msg =
        AssistantMessage.new(@theme,
          stop_reason: :error,
          error_message: "fail",
          has_tool_calls: true
        )

      lines = AssistantMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      refute Enum.any?(stripped, &(&1 =~ "fail"))
    end
  end

  # ── OSC 133 zones ───────────────────────────────────────────────

  describe "OSC 133 command zones" do
    test "wraps output in OSC 133 markers when no tool calls" do
      msg = AssistantMessage.new(@theme, content: [{:text, "hello"}])
      lines = AssistantMessage.render(msg, 80)
      first = hd(lines)
      last = List.last(lines)
      assert first =~ "\e]133;A\a"
      assert last =~ "\e]133;B\a"
    end

    test "skips OSC 133 when has_tool_calls" do
      msg =
        AssistantMessage.new(@theme,
          content: [{:text, "hello"}],
          has_tool_calls: true
        )

      lines = AssistantMessage.render(msg, 80)
      first = hd(lines)
      refute first =~ "\e]133;"
    end
  end

  # ── Update ──────────────────────────────────────────────────────

  describe "update_content/2" do
    test "replaces content" do
      msg = AssistantMessage.new(@theme, content: [{:text, "old"}])
      updated = AssistantMessage.update_content(msg, content: [{:text, "new"}])
      lines = AssistantMessage.render(updated, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "new"))
      refute Enum.any?(stripped, &(&1 =~ "old"))
    end
  end
end
