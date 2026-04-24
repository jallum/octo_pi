defmodule OctoPi.TUI.Components.TruncatedTextTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.TruncatedText
  alias OctoPi.TUI.WrapAnsi

  defp strip_ansi(s), do: String.replace(s, ~r/\e\[[0-9;]*m/, "")

  describe "render/2 — upstream truncated-text.test.ts parity" do
    test "pads output lines to exactly match width" do
      lines = TruncatedText.render(%TruncatedText{text: "Hello world", padding_x: 1}, 50)
      assert length(lines) == 1
      assert WrapAnsi.visible_width(hd(lines)) == 50
    end

    test "pads output with vertical padding lines to width" do
      lines = TruncatedText.render(%TruncatedText{text: "Hello", padding_y: 2}, 40)
      assert length(lines) == 5
      for line <- lines, do: assert(WrapAnsi.visible_width(line) == 40)
    end

    test "truncates long text and pads to width" do
      long = "This is a very long piece of text that will definitely exceed the available width"
      [line] = TruncatedText.render(%TruncatedText{text: long, padding_x: 1}, 30)
      assert WrapAnsi.visible_width(line) == 30
      assert String.contains?(strip_ansi(line), "...")
    end

    test "preserves ANSI codes in output and pads correctly" do
      styled = "\e[31mHello\e[0m \e[34mworld\e[0m"
      [line] = TruncatedText.render(%TruncatedText{text: styled, padding_x: 1}, 40)
      assert WrapAnsi.visible_width(line) == 40
      assert String.contains?(line, "\e[")
    end

    test "truncates styled text and adds reset code before ellipsis" do
      styled = "\e[31mThis is a very long red text that will be truncated\e[0m"
      [line] = TruncatedText.render(%TruncatedText{text: styled, padding_x: 1}, 20)
      assert WrapAnsi.visible_width(line) == 20
      assert String.contains?(line, "\e[0m...")
    end

    test "handles text that fits exactly" do
      [line] = TruncatedText.render(%TruncatedText{text: "Hello world", padding_x: 1}, 30)
      assert WrapAnsi.visible_width(line) == 30
      refute String.contains?(strip_ansi(line), "...")
    end

    test "handles empty text" do
      [line] = TruncatedText.render(%TruncatedText{text: "", padding_x: 1}, 30)
      assert WrapAnsi.visible_width(line) == 30
    end

    test "stops at newline and only shows first line" do
      text = "First line\nSecond line\nThird line"
      [line] = TruncatedText.render(%TruncatedText{text: text, padding_x: 1}, 40)
      assert WrapAnsi.visible_width(line) == 40
      stripped = strip_ansi(line)
      assert String.contains?(stripped, "First line")
      refute String.contains?(stripped, "Second line")
      refute String.contains?(stripped, "Third line")
    end

    test "truncates first line even with newlines in text" do
      text = "This is a very long first line that needs truncation\nSecond line"
      [line] = TruncatedText.render(%TruncatedText{text: text, padding_x: 1}, 25)
      assert WrapAnsi.visible_width(line) == 25
      stripped = strip_ansi(line)
      assert String.contains?(stripped, "...")
      refute String.contains?(stripped, "Second line")
    end
  end
end
