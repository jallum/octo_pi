defmodule OctoPi.TUI.VDOM.PaintTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.VDOM.LineBuf
  alias OctoPi.TUI.VDOM.Paint
  alias Paint.RenderCtx

  describe "basic nodes" do
    test "paint VText" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VText{text: "hello", width: 5}
      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      assert binary_from_iolist(iolist) =~ "hello"
    end

    test "paint VLines" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VLines{lines: ["line1", "line2"]}
      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      assert result =~ "line1"
      assert result =~ "line2"
      assert result =~ "\n"
    end

    test "paint VFlow with text children" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VFlow{children: ["a\n", "b\n", "c"]}
      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      lines = String.split(result, "\n")
      assert "a" in lines
      assert "b" in lines
      assert "c" in lines
    end

    test "paint VRow concatenates inline" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VRow{children: ["a", "b", "c"]}
      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      # All on one line
      refute result =~ "\n"
      assert result =~ "abc"
    end

    test "paint VCursor marks position" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VCursor{style: :bar}

      {_, cursor} =
        node
        |> Paint.paint(LineBuf.push(LineBuf.new(), "prefix"), ctx)
        |> LineBuf.finalize()

      assert cursor == {0, 6, :bar}
    end

    test "paint VCursor with style" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VCursor{style: :block}

      {_, cursor} =
        node
        |> Paint.paint(LineBuf.push(LineBuf.new(), "prefix"), ctx)
        |> LineBuf.finalize()

      assert cursor == {0, 6, :block}
    end

    test "VFlow with VText" do
      ctx = %RenderCtx{width: 80}
      text = %VDOM.VText{text: "hello", width: 5}
      node = %VDOM.VFlow{children: [text]}
      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      assert binary_from_iolist(iolist) =~ "hello"
    end

    test "VFlow with nested list children (rule #1)" do
      ctx = %RenderCtx{width: 80}

      children =
        for i <- 1..100 do
          %VDOM.VText{text: "line#{i}", width: 6}
        end

      node = %VDOM.VFlow{children: children}

      # Performance check (not enabled yet - wait for memo)
      :timer.tc(fn ->
        node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      end)

      :ok
    end

    test "VMemo with returned list children (rule #2)" do
      ctx = %RenderCtx{width: 80}
      lines = [%VDOM.VText{text: "a", width: 1}, %VDOM.VText{text: "b", width: 1}]

      memo = %VDOM.VMemo{
        key: :test,
        thunk: fn -> lines end,
        cell: nil
      }

      memo |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      # VMemo implementation is stubbed - just ensure it doesn't crash
      # Full memo tests come in d06.2
    end

    test "VZone single-line zone: both markers on that line" do
      ctx = %RenderCtx{width: 40}
      zone = %VDOM.VZone{type: :prompt, id: "z1", children: [%VDOM.VLines{lines: ["hello"]}]}

      {iolist, _} = zone |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      lines = result |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert length(lines) == 1
      assert hd(lines) =~ "\e]133;A\a"
      assert hd(lines) =~ "\e]133;B\a"
    end

    test "VZone multi-line zone: open on first line, close on last line" do
      ctx = %RenderCtx{width: 40}

      zone = %VDOM.VZone{
        type: :output,
        id: "z2",
        children: [%VDOM.VLines{lines: ["line1", "line2", "line3"]}]
      }

      {iolist, _} = zone |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      lines = result |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert length(lines) == 3
      assert hd(lines) =~ "\e]133;A\a"
      refute hd(lines) =~ "\e]133;B\a"
      assert List.last(lines) =~ "\e]133;B\a"
      refute List.last(lines) =~ "\e]133;A\a"
      assert lines |> Enum.at(1) |> then(&(not (&1 =~ "\e]133;")))
    end

    test "VZone empty zone: both markers on one flushed line" do
      ctx = %RenderCtx{width: 40}
      zone = %VDOM.VZone{type: :prompt, id: "empty", children: []}

      {iolist, _} = zone |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      lines = result |> String.split("\n") |> Enum.reject(&(&1 == ""))

      assert length(lines) == 1
      assert hd(lines) =~ "\e]133;A\a"
      assert hd(lines) =~ "\e]133;B\a"
    end

    test "VZone nested zones: no interference" do
      ctx = %RenderCtx{width: 40}

      inner = %VDOM.VZone{type: :prompt, id: "inner", children: [%VDOM.VLines{lines: ["hi"]}]}
      outer = %VDOM.VZone{type: :output, id: "outer", children: [inner]}

      {iolist, _} = outer |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)

      assert result =~ "hi"
      assert result |> String.split("\e]133;A\a") |> length() == 3
    end

    test "VBox with border and padding" do
      ctx = %RenderCtx{width: 20}

      node = %VDOM.VBox{
        border?: true,
        padding_x: 1,
        padding_y: 1,
        children: [%VDOM.VText{text: "content", width: 7}]
      }

      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)

      # Should contain border characters
      assert result =~ "┌"
      assert result =~ "┐"
      assert result =~ "└"
      assert result =~ "┘"
      assert result =~ "│"
    end

    test "VBox without border, with padding" do
      ctx = %RenderCtx{width: 20}

      node = %VDOM.VBox{
        border?: false,
        padding_x: 2,
        padding_y: 1,
        children: [%VDOM.VText{text: "x", width: 1}]
      }

      {iolist, _} = node |> Paint.paint(LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)

      # Should have padded lines (spaces)
      assert result =~ "  x"
    end
  end

  ## Test helpers

  defp binary_from_iolist(iodata) do
    IO.iodata_to_binary(iodata)
  end
end
