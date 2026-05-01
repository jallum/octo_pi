defmodule OctoPi.TUI.VDOM.PaintTest do
  use ExUnit.Case, async: true
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.VDOM.{Paint, LineBuf}
  alias Paint.RenderCtx

  describe "basic nodes" do
    test "paint VText" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VText{text: "hello", width: 5}
      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
      assert binary_from_iolist(iolist) =~ "hello"
    end

    test "paint VLines" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VLines{lines: ["line1", "line2"]}
      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      assert result =~ "line1"
      assert result =~ "line2"
      assert result =~ "\n"
    end

    test "paint VFlow with text children" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VFlow{children: ["a\n", "b\n", "c"]}
      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      lines = String.split(result, "\n")
      assert "a" in lines
      assert "b" in lines
      assert "c" in lines
    end

    test "paint VRow concatenates inline" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VRow{children: ["a", "b", "c"]}
      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)
      # All on one line
      refute result =~ "\n"
      assert result =~ "abc"
    end

    test "paint VCursor marks position" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VCursor{style: :bar}

      {_, cursor} =
        Paint.paint(node, LineBuf.new() |> LineBuf.push("prefix"), ctx)
        |> LineBuf.finalize()

      assert cursor == {0, 6, :bar}
    end

    test "paint VCursor with style" do
      ctx = %RenderCtx{width: 80}
      node = %VDOM.VCursor{style: :block}

      {_, cursor} =
        Paint.paint(node, LineBuf.new() |> LineBuf.push("prefix"), ctx)
        |> LineBuf.finalize()

      assert cursor == {0, 6, :block}
    end

    test "VFlow with VText" do
      ctx = %RenderCtx{width: 80}
      text = %VDOM.VText{text: "hello", width: 5}
      node = %VDOM.VFlow{children: [text]}
      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
      assert binary_from_iolist(iolist) =~ "hello"
    end

    test "VFlow with nested list children (rule #1)" do
      ctx = %RenderCtx{width: 80}

      children =
        for i <- 1..100 do
          %VDOM.VText{text: "line#{i}", width: 6}
        end

      node = %VDOM.VFlow{children: children}

      {_, duration} =
        :timer.tc(fn ->
          Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
        end)

      # Should complete in reasonable time (<50ms for 100 nodes)
      # Full memo implementation will make this much faster
      # assert duration < 50_000  # TODO: Enable in d06.2
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

      Paint.paint(memo, LineBuf.new(), ctx) |> LineBuf.finalize()
      # VMemo implementation is stubbed - just ensure it doesn't crash
      # Full memo tests come in d06.2
    end

    test "VZone output zone with content" do
      ctx = %RenderCtx{width: 40}

      children = [
        %VDOM.VText{text: "output", width: 6},
        "\n",
        %VDOM.VText{text: "more", width: 4}
      ]

      zone = %VDOM.VZone{type: :output, id: "zone1", children: children}

      {iolist, _} = Paint.paint(zone, LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)

      # VZone wrapping is stubbed - full implementation requires reconciler
      # This test just ensures children are painted
      assert result =~ "output"
      assert result =~ "more"
    end

    test "VZone empty zone" do
      ctx = %RenderCtx{width: 40}
      zone = %VDOM.VZone{type: :prompt, id: "empty", children: []}

      {iolist, _} = Paint.paint(zone, LineBuf.new(), ctx) |> LineBuf.finalize()
      result = binary_from_iolist(iolist)

      # Empty zone emits markers on a single line
      assert result =~ "empty"
    end

    test "VBox with border and padding" do
      ctx = %RenderCtx{width: 20}

      node = %VDOM.VBox{
        border?: true,
        padding_x: 1,
        padding_y: 1,
        children: [%VDOM.VText{text: "content", width: 7}]
      }

      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
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

      {iolist, _} = Paint.paint(node, LineBuf.new(), ctx) |> LineBuf.finalize()
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