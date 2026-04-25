defmodule OctoPi.TUI.Components.TextTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Text

  describe "render/2" do
    test "single line passes through unchanged" do
      assert ["hello"] = Text.render(%Text{content: "hello"}, 80)
    end

    test "splits on newlines" do
      assert ["a", "b", "c"] = Text.render(%Text{content: "a\nb\nc"}, 80)
    end

    test "truncates lines exceeding width" do
      assert ["hello"] = Text.render(%Text{content: "hello world"}, 5)
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
  end
end
