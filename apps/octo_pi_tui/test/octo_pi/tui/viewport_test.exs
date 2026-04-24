defmodule OctoPi.TUI.ViewportTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Viewport

  describe "window/2" do
    test "returns all lines when content fits within height" do
      lines = ["line 1", "line 2", "line 3"]
      assert Viewport.window(lines, 5) == lines
    end

    test "returns all lines when content exactly matches height" do
      lines = ["a", "b", "c"]
      assert Viewport.window(lines, 3) == lines
    end

    test "returns the tail when content exceeds height" do
      lines = ["1", "2", "3", "4", "5"]
      assert Viewport.window(lines, 3) == ["3", "4", "5"]
    end

    test "single-line height returns last line" do
      assert Viewport.window(["a", "b", "c"], 1) == ["c"]
    end

    test "empty list returns empty" do
      assert Viewport.window([], 10) == []
    end
  end
end
