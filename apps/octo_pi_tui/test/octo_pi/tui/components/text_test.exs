defmodule OctoPi.TUI.Components.TextTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Text

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  describe "render/2" do
    test "single line passes through unchanged" do
      assert ["hello"] = Text.render(%Text{content: "hello"}, 80)
    end

    test "splits on newlines" do
      assert ["a", "b", "c"] = Text.render(%Text{content: "a\nb\nc"}, 80)
    end

    test "truncates lines exceeding width" do
      [line] = Text.render(%Text{content: "hello world"}, 5)
      assert strip_ansi(line) == "hello"
    end

    test "empty content is a single empty line" do
      assert [""] = Text.render(%Text{content: ""}, 80)
    end

    test "preserves ANSI codes in truncation (byte count)" do
      styled = "\e[31mred\e[0m"
      assert [^styled] = Text.render(%Text{content: styled}, 80)
    end

    test "expands tabs to 3 spaces" do
      assert ["      indented"] = Text.render(%Text{content: "\t\tindented"}, 80)
    end

    test "expands tabs in cat -n style output" do
      [line] = Text.render(%Text{content: "  42\tif true do"}, 80)
      refute line =~ "\t"
      assert line == "  42   if true do"
    end

    test "truncation does not break ANSI escape sequences" do
      # A line with ANSI color codes that is visually short but byte-heavy.
      # Truncating by grapheme count would cut mid-escape, leaving raw codes visible.
      styled = "\e[38;2;106;153;85m# comment\e[39m and more text after"
      [line] = Text.render(%Text{content: styled}, 15)

      stripped = strip_ansi(line)
      assert String.length(stripped) <= 15
      refute Regex.match?(~r/\d+;\d+;\d+m/, stripped),
             "raw ANSI code fragments should not appear as visible text: #{inspect(stripped)}"
    end

    test "truncation preserves complete ANSI sequences" do
      styled = "\e[31mred\e[0m \e[32mgreen\e[0m \e[34mblue\e[0m"
      [line] = Text.render(%Text{content: styled}, 10)

      # Should contain "red" and not have broken escape sequences
      assert line =~ "red"
      refute Regex.match?(~r/(?<!\e)\[[\d;]*m/, line),
             "should not have orphaned ANSI fragments"
    end
  end
end
