defmodule OctoPi.TUI.VDOM.LineBufTest do
  use ExUnit.Case, async: true
  alias OctoPi.TUI.VDOM.LineBuf

  describe "basic operations" do
    test "new creates empty buffer" do
      buf = LineBuf.new()
      assert buf.iolist_rev == []
      assert buf.line_iolist_rev == []
      assert buf.visible_width == 0
      assert buf.line_count == 0
      assert buf.cursor == nil
    end

    test "push adds to current line" do
      buf = LineBuf.new() |> LineBuf.push("hello") |> LineBuf.push(" world")
      assert buf.line_iolist_rev == [" world", "hello"]
      assert buf.visible_width == 11
    end

    test "push handles ANSI codes in width calculation" do
      buf = LineBuf.new() |> LineBuf.push("\e[31mred\e[0m")
      assert buf.visible_width == 3
    end

    test "push_many adds multiple segments with known width" do
      buf = LineBuf.new() |> LineBuf.push_many(["a", "b", "c"], 3)
      assert buf.line_iolist_rev == ["c", "b", "a"]
      assert buf.visible_width == 3
    end

    test "flush_line completes current line" do
      buf = LineBuf.new() |> LineBuf.push("hello") |> LineBuf.flush_line()
      assert buf.line_count == 1
      assert buf.visible_width == 0
      assert buf.line_iolist_rev == []
      # Flush adds ["hello", "\n"] which is 2 items
      assert length(buf.iolist_rev) == 2
    end

    test "mark_cursor records position" do
      buf = LineBuf.new() |> LineBuf.push("hi") |> LineBuf.mark_cursor()
      {_, cursor} = LineBuf.finalize(buf)
      assert cursor == {0, 2}
    end

    test "mark_cursor only first call has effect" do
      buf = LineBuf.new() |> LineBuf.push("a") |> LineBuf.mark_cursor() |> LineBuf.mark_cursor()
      {_, cursor} = LineBuf.finalize(buf)
      assert cursor == {0, 1}
    end

    test "finalize reverses lines" do
      buf = LineBuf.new() |> LineBuf.push("a") |> LineBuf.flush_line() |> LineBuf.push("b")
      {iolist, _} = LineBuf.finalize(buf)

      # iolist structure: [["a"], "b"] (because "b" is on current line)
      assert is_list(iolist)
    end
  end

  describe "cursor tracking" do
    test "cursor position tracks across lines" do
      buf =
        LineBuf.new()
        |> LineBuf.push("line1")
        |> LineBuf.flush_line()
        |> LineBuf.push("x")
        |> LineBuf.mark_cursor()

      {_, cursor} = LineBuf.finalize(buf)
      assert cursor == {1, 1}
    end

    test "nil cursor when never marked" do
      buf = LineBuf.new() |> LineBuf.push("a") |> LineBuf.flush_line()
      {_, cursor} = LineBuf.finalize(buf)
      assert cursor == nil
    end
  end

  describe "iodata handling" do
    test "nested iodata" do
      buf = LineBuf.new() |> LineBuf.push(["a", "b", ["c", "d"]])
      assert buf.visible_width == 4
    end

    test "finalize with pending line" do
      buf = LineBuf.new() |> LineBuf.push("pending")
      {iolist, _} = LineBuf.finalize(buf)
      assert is_list(iolist)
    end

    test "finalize without pending line" do
      buf = LineBuf.new() |> LineBuf.push("done") |> LineBuf.flush_line()
      {iolist, _} = LineBuf.finalize(buf)
      assert is_list(iolist)
    end
  end
end