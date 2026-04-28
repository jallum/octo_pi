defmodule OctoPi.TUI.VirtualTerminalTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.VirtualTerminal, as: VT

  describe "new/2" do
    test "creates a blank grid of the right size" do
      vt = VT.new(80, 24)
      viewport = VT.get_viewport(vt)
      assert length(viewport) == 24
      assert Enum.all?(viewport, &(&1 == ""))
    end

    test "cursor starts at 0,0" do
      assert {0, 0} = VT.get_cursor(VT.new(80, 24))
    end
  end

  describe "write/2 — printable text" do
    test "writes text at cursor position" do
      vt = 80 |> VT.new(5) |> VT.write("hello")
      assert hd(VT.get_viewport(vt)) == "hello"
      assert {0, 5} = VT.get_cursor(vt)
    end

    test "does not overflow past cols" do
      vt = 3 |> VT.new(1) |> VT.write("abcde")
      assert hd(VT.get_viewport(vt)) == "abc"
    end
  end

  describe "write/2 — cursor positioning" do
    test "CSI H homes the cursor" do
      vt = 80 |> VT.new(5) |> VT.write("hello") |> VT.write("\e[H")
      assert {0, 0} = VT.get_cursor(vt)
    end

    test "CSI row;col H positions absolutely (1-indexed)" do
      vt = 80 |> VT.new(5) |> VT.write("\e[3;10H")
      assert {2, 9} = VT.get_cursor(vt)
    end

    test "CSI row;1H positions to start of row" do
      vt = 80 |> VT.new(5) |> VT.write("\e[4;1H") |> VT.write("line4")
      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 3) == "line4"
    end
  end

  describe "write/2 — clear operations" do
    test "CSI 2J clears the screen" do
      vt =
        80
        |> VT.new(3)
        |> VT.write("hello")
        |> VT.write("\e[2J")

      assert VT.get_viewport(vt) == ["", "", ""]
    end

    test "CSI K clears from cursor to end of line" do
      vt =
        80
        |> VT.new(3)
        |> VT.write("hello world")
        |> VT.write("\e[1;6H")
        |> VT.write("\e[K")

      assert hd(VT.get_viewport(vt)) == "hello"
    end
  end

  describe "write/2 — newlines" do
    test "\\r\\n moves to start of next line" do
      vt = 80 |> VT.new(5) |> VT.write("line1\r\nline2")
      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 0) == "line1"
      assert Enum.at(viewport, 1) == "line2"
    end

    test "scrolls when at bottom row" do
      vt =
        80
        |> VT.new(3)
        |> VT.write("row0\r\nrow1\r\nrow2\r\nrow3")

      viewport = VT.get_viewport(vt)
      # row0 scrolled off, row1 is now at top
      assert Enum.at(viewport, 0) == "row1"
      assert Enum.at(viewport, 1) == "row2"
      assert Enum.at(viewport, 2) == "row3"
    end
  end

  describe "write/2 — synchronized output" do
    test "CSI ?2026h and CSI ?2026l are ignored" do
      vt = 80 |> VT.new(3) |> VT.write("\e[?2026hhello\e[?2026l")
      assert hd(VT.get_viewport(vt)) == "hello"
    end
  end

  describe "Renderer integration" do
    test "full redraw renders correctly" do
      alias OctoPi.TUI.Renderer

      {:ok, r} = Renderer.start_link(width: 40, height: 5, min_interval_ms: 0)
      {:ok, bytes} = Renderer.render(r, ["hello", "world"])

      vt = 40 |> VT.new(5) |> VT.write(bytes)
      viewport = VT.get_viewport(vt)

      assert Enum.at(viewport, 0) == "hello"
      assert Enum.at(viewport, 1) == "world"
    end

    test "differential render updates only changed lines" do
      alias OctoPi.TUI.Renderer

      {:ok, r} = Renderer.start_link(width: 40, height: 5, min_interval_ms: 0)

      {:ok, bytes1} = Renderer.render(r, ["aaa", "bbb", "ccc"])
      vt = 40 |> VT.new(5) |> VT.write(bytes1)

      {:ok, bytes2} = Renderer.render(r, ["aaa", "XXX", "ccc"])
      vt = VT.write(vt, bytes2)

      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 0) == "aaa"
      assert Enum.at(viewport, 1) == "XXX"
      assert Enum.at(viewport, 2) == "ccc"
    end

    test "shrink clears stale rows" do
      alias OctoPi.TUI.Renderer

      {:ok, r} = Renderer.start_link(width: 40, height: 10, min_interval_ms: 0)

      {:ok, bytes1} = Renderer.render(r, ["a", "b", "c", "d", "e"])
      vt = 40 |> VT.new(10) |> VT.write(bytes1)

      {:ok, bytes2} = Renderer.render(r, ["a", "b"])
      vt = VT.write(vt, bytes2)

      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 0) == "a"
      assert Enum.at(viewport, 1) == "b"
      assert Enum.at(viewport, 2) == ""
      assert Enum.at(viewport, 3) == ""
      assert Enum.at(viewport, 4) == ""
    end

    test "resize then render clears and redraws" do
      alias OctoPi.TUI.Renderer

      {:ok, r} = Renderer.start_link(width: 40, height: 5, min_interval_ms: 0)

      {:ok, bytes1} = Renderer.render(r, ["old1", "old2", "old3"])
      vt = 40 |> VT.new(5) |> VT.write(bytes1)

      :ok = Renderer.resize(r, 60, 8)
      {:ok, bytes2} = Renderer.render(r, ["new1", "new2"])
      vt = vt |> VT.resize(60, 8) |> VT.write(bytes2)

      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 0) == "new1"
      assert Enum.at(viewport, 1) == "new2"
      assert Enum.at(viewport, 2) == ""
    end

    test "spinner animation: only middle line changes" do
      alias OctoPi.TUI.Renderer

      {:ok, r} = Renderer.start_link(width: 40, height: 5, min_interval_ms: 0)

      {:ok, bytes1} = Renderer.render(r, ["Header", "⠋ Working...", "Footer"])
      vt = 40 |> VT.new(5) |> VT.write(bytes1)

      {:ok, bytes2} = Renderer.render(r, ["Header", "⠙ Working...", "Footer"])
      vt = VT.write(vt, bytes2)

      {:ok, bytes3} = Renderer.render(r, ["Header", "⠹ Working...", "Footer"])
      vt = VT.write(vt, bytes3)

      viewport = VT.get_viewport(vt)
      assert Enum.at(viewport, 0) == "Header"
      assert Enum.at(viewport, 1) == "⠹ Working..."
      assert Enum.at(viewport, 2) == "Footer"
    end
  end

  describe "SGR attribute tracking" do
    test "italic on/off applies to written cells only" do
      vt = 20 |> VT.new(3) |> VT.write("\e[3mIT\e[23mPL")
      assert VT.cell_italic?(vt, 0, 0)
      assert VT.cell_italic?(vt, 0, 1)
      refute VT.cell_italic?(vt, 0, 2)
      refute VT.cell_italic?(vt, 0, 3)
    end

    test "bold / underline tracked independently" do
      vt = 10 |> VT.new(1) |> VT.write("\e[1mB\e[22m\e[4mU\e[24mX")
      assert VT.cell_attrs(vt, 0, 0).bold
      refute VT.cell_attrs(vt, 0, 0).underline
      assert VT.cell_attrs(vt, 0, 1).underline
      refute VT.cell_attrs(vt, 0, 1).bold
      refute VT.cell_attrs(vt, 0, 2).underline
    end

    test "full reset clears all attrs" do
      vt = 10 |> VT.new(1) |> VT.write("\e[1;3;4mX\e[0mY")
      attrs0 = VT.cell_attrs(vt, 0, 0)
      assert attrs0.bold and attrs0.italic and attrs0.underline
      attrs1 = VT.cell_attrs(vt, 0, 1)
      refute attrs1.bold
      refute attrs1.italic
      refute attrs1.underline
    end
  end
end
