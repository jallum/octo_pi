defmodule OctoPi.TUI.OverlayTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Overlay
  alias OctoPi.TUI.VirtualTerminal

  defp ov(fields), do: struct!(Overlay, fields)

  defp base_grid(w, h) do
    for r <- 0..(h - 1), do: String.duplicate(to_string(rem(r, 10)), w)
  end

  describe "anchor_row/4" do
    test "top anchors place at margin_top" do
      for a <- [:top_left, :top_center, :top_right] do
        assert 2 == Overlay.anchor_row(a, 5, 20, 2)
      end
    end

    test "bottom anchors place at margin_top + avail - height" do
      for a <- [:bottom_left, :bottom_center, :bottom_right] do
        assert 17 == Overlay.anchor_row(a, 5, 20, 2)
      end
    end

    test "center anchors vertically center" do
      assert 9 == Overlay.anchor_row(:center, 6, 20, 2)
    end
  end

  describe "anchor_col/4" do
    test "left anchors place at margin_left" do
      for a <- [:top_left, :left_center, :bottom_left] do
        assert 3 == Overlay.anchor_col(a, 10, 40, 3)
      end
    end

    test "right anchors place at margin_left + avail - width" do
      for a <- [:top_right, :right_center, :bottom_right] do
        assert 33 == Overlay.anchor_col(a, 10, 40, 3)
      end
    end

    test "center anchors horizontally center" do
      assert 18 == Overlay.anchor_col(:center, 10, 40, 3)
    end
  end

  describe "resolve_and_clip/3" do
    test "default center with no options" do
      ov = ov(lines: ["AAAA", "BBBB"], width: 4)
      {row, col, w, lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert w == 4
      assert length(lines) == 2
      assert row == 4
      assert col == 8
    end

    test "top-left anchor with margin" do
      ov = ov(lines: ["XX"], width: 2, anchor: :top_left, margin: 1)
      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 1
      assert col == 1
    end

    test "bottom-right anchor" do
      ov = ov(lines: ["XX"], width: 2, anchor: :bottom_right)
      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 9
      assert col == 18
    end

    test "percentage width" do
      ov = ov(lines: ["test"], width: {50, :percent})
      {_row, _col, w, _lines} = Overlay.resolve_and_clip(ov, 80, 24)
      assert w == 40
    end

    test "min_width enforced" do
      ov = ov(lines: ["x"], width: 5, min_width: 10)
      {_row, _col, w, _lines} = Overlay.resolve_and_clip(ov, 80, 24)
      assert w == 10
    end

    test "max_height clips lines" do
      ov = ov(lines: Enum.map(1..10, &"line #{&1}"), width: 10, max_height: 3)
      {_row, _col, _w, lines} = Overlay.resolve_and_clip(ov, 80, 24)
      assert length(lines) == 3
    end

    test "percentage max_height" do
      ov = ov(lines: Enum.map(1..20, &"line #{&1}"), width: 10, max_height: {50, :percent})
      {_row, _col, _w, lines} = Overlay.resolve_and_clip(ov, 80, 24)
      assert length(lines) == 12
    end

    test "percentage row and col" do
      ov = ov(lines: ["XX"], width: 2, row: {50, :percent}, col: {50, :percent})
      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 4
      assert col == 9
    end

    test "absolute row and col override anchor" do
      ov = ov(lines: ["XX"], width: 2, anchor: :top_left, row: 5, col: 10)
      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 5
      assert col == 10
    end

    test "offset_x and offset_y applied after positioning" do
      ov = ov(lines: ["XX"], width: 2, anchor: :top_left, offset_x: 3, offset_y: 2)
      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 2
      assert col == 3
    end

    test "negative margins clamped to zero" do
      ov =
        ov(
          lines: ["XX"],
          width: 2,
          anchor: :top_left,
          margin: %{top: -5, left: -3, right: 0, bottom: 0}
        )

      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 0
      assert col == 0
    end

    test "map margin with individual sides" do
      ov =
        ov(
          lines: ["XX"],
          width: 2,
          anchor: :top_left,
          margin: %{top: 2, left: 5, right: 0, bottom: 0}
        )

      {row, col, _w, _lines} = Overlay.resolve_and_clip(ov, 20, 10)
      assert row == 2
      assert col == 5
    end
  end

  describe "composite/4" do
    test "no overlays returns base unchanged" do
      base = ["hello", "world"]
      assert base == Overlay.composite(base, [], 10, 5)
    end

    test "single overlay paints onto base" do
      base = base_grid(10, 5)
      ov = ov(lines: ["AB", "CD"], width: 2, anchor: :top_left)
      result = Overlay.composite(base, [ov], 10, 5)

      line0 = Enum.at(result, 0)
      assert line0 =~ "AB"

      line1 = Enum.at(result, 1)
      assert line1 =~ "CD"
    end

    test "stacked overlays: higher z paints on top" do
      base = base_grid(10, 5)

      ov1 = ov(lines: ["XXXX"], width: 4, anchor: :top_left, z: 0)
      ov2 = ov(lines: ["YY"], width: 2, anchor: :top_left, z: 1)

      result = Overlay.composite(base, [ov2, ov1], 10, 5)
      line0 = Enum.at(result, 0)
      assert line0 =~ "YY"
    end

    test "overlay clipped to terminal width" do
      alias OctoPi.TUI.WrapAnsi

      base = ["abcde"]
      ov = ov(lines: ["OVERLAY"], width: 5, anchor: :top_left)
      result = Overlay.composite(base, [ov], 5, 1)

      line0 = Enum.at(result, 0)
      assert WrapAnsi.visible_width(line0) <= 5
    end

    test "OSC 8 in base content does not crash" do
      base = ["\e]8;;http://example.com\e\\link\e]8;;\e\\"]
      ov = ov(lines: ["OV"], width: 2, anchor: :top_left)
      result = Overlay.composite(base, [ov], 20, 1)
      assert is_list(result)
    end

    test "italic does not leak past trailing reset beyond visible column" do
      # Regression (upstream tui-overlay-style-leak.test.ts): an
      # italic line followed by a plain line must not make the
      # plain line's cells italic in the terminal buffer.
      alias OctoPi.TUI.Renderer
      alias VirtualTerminal, as: VT

      width = 20
      {:ok, r} = Renderer.start_link(width: width, height: 6)
      base_line = "\e[3m" <> String.duplicate("X", width) <> "\e[23m"
      lines = [base_line, "INPUT", "", "", "", ""]

      {:ok, bytes} = Renderer.render(r, lines)
      vt = width |> VT.new(6) |> VT.write(bytes)

      refute VT.cell_italic?(vt, 1, 0), "italic leaked to plain INPUT row"
    end

    # --- upstream overlay-options.test.ts integration parity ---

    test "overlay lines wider than declared width are clipped" do
      alias OctoPi.TUI.WrapAnsi

      base = base_grid(80, 24)
      ov = ov(lines: [String.duplicate("X", 100)], width: 20, anchor: :top_left)
      result = Overlay.composite(base, [ov], 80, 24)
      line0 = Enum.at(result, 0)

      # Overlay cannot introduce more than 20 overlaid cells over the
      # base row (each base row starts at 80 visible cols).
      assert WrapAnsi.visible_width(line0) == 80
    end

    test "overlay with complex ANSI + OSC sequences does not crash" do
      base = base_grid(80, 24)

      complex =
        "\e[48;2;40;50;40m \e[38;2;128;128;128mstyled\e[39m\e[49m" <>
          "\e]8;;http://example.com\x07link\e]8;;\x07" <>
          " content"

      ov = ov(lines: [complex, complex, complex], width: 60, anchor: :center)
      result = Overlay.composite(base, [ov], 80, 24)
      assert is_list(result)
    end

    test "overlay composited on styled base content remains visible" do
      styled = "\e[1m\e[38;2;255;0;0m" <> String.duplicate("X", 80) <> "\e[0m"
      base = List.duplicate(styled, 24)

      ov = ov(lines: ["OVERLAY"], width: 20, anchor: :center)
      result = Overlay.composite(base, [ov], 80, 24)
      assert Enum.any?(result, &String.contains?(&1, "OVERLAY"))
    end

    test "wide CJK characters at overlay boundary do not crash" do
      base = base_grid(80, 24)
      wide = "中文日本語한글テスト漢字"
      ov = ov(lines: [wide], width: 15, anchor: :center)
      result = Overlay.composite(base, [ov], 80, 24)
      assert is_list(result)
    end

    test "overlay positioned at terminal right edge does not crash" do
      base = base_grid(80, 24)
      ov = ov(lines: [String.duplicate("X", 50)], col: 60, width: 20, anchor: :top_left)
      result = Overlay.composite(base, [ov], 80, 24)
      assert is_list(result)
    end

    test "rowPercent 0 places overlay at the top" do
      base = base_grid(80, 24)
      ov = ov(lines: ["TOP"], width: 10, row: {0, :percent})
      result = Overlay.composite(base, [ov], 80, 24)
      assert Enum.at(result, 0) =~ "TOP"
    end

    test "rowPercent 100 places overlay at the bottom" do
      base = base_grid(80, 24)
      ov = ov(lines: ["BOTTOM"], width: 10, row: {100, :percent})
      result = Overlay.composite(base, [ov], 80, 24)
      assert List.last(result) =~ "BOTTOM"
    end

    test "higher z overlay covers lower z overlay at same anchor" do
      base = base_grid(80, 24)
      ov_lo = ov(lines: ["LOWWWWWW"], width: 8, anchor: :top_left, z: 0)
      ov_hi = ov(lines: ["HI"], width: 2, anchor: :top_left, z: 1)
      result = Overlay.composite(base, [ov_lo, ov_hi], 80, 24)
      line0 = Enum.at(result, 0)
      assert line0 =~ "HI"
    end

    test "overlays at different anchors render without interference" do
      base = base_grid(80, 24)
      ov_tl = ov(lines: ["TOP_LEFT"], width: 10, anchor: :top_left)
      ov_br = ov(lines: ["BOTTOM_RIGHT"], width: 15, anchor: :bottom_right)
      result = Overlay.composite(base, [ov_tl, ov_br], 80, 24)
      assert Enum.at(result, 0) =~ "TOP_LEFT"
      assert List.last(result) =~ "BOTTOM_RIGHT"
    end

    test "italic does not leak when overlay slicing drops trailing resets" do
      alias OctoPi.TUI.Renderer
      alias VirtualTerminal, as: VT

      width = 20
      {:ok, r} = Renderer.start_link(width: width, height: 6)
      base_line = "\e[3m" <> String.duplicate("X", width) <> "\e[23m"
      base = [base_line, "INPUT", "", "", "", ""]
      overlay = %Overlay{lines: ["OVR"], width: 3, anchor: :top_left, row: 0, col: 5}
      composed = Overlay.composite(base, [overlay], width, 6)

      {:ok, bytes} = Renderer.render(r, composed)
      vt = width |> VT.new(6) |> VT.write(bytes)

      refute VT.cell_italic?(vt, 1, 0), "italic leaked to INPUT row after overlay slice"
    end
  end

  describe "composite_line/5" do
    test "paints overlay in middle of base" do
      result = Overlay.composite_line("0123456789", "AB", 3, 2, 10)
      stripped = String.replace(result, ~r/\e\[[0-9;]*m/, "")
      assert stripped == "012AB56789"
    end

    test "paints overlay at start" do
      result = Overlay.composite_line("0123456789", "XY", 0, 2, 10)
      stripped = String.replace(result, ~r/\e\[[0-9;]*m/, "")
      assert stripped == "XY23456789"
    end

    test "paints overlay at end" do
      result = Overlay.composite_line("0123456789", "ZZ", 8, 2, 10)
      stripped = String.replace(result, ~r/\e\[[0-9;]*m/, "")
      assert stripped == "01234567ZZ"
    end

    test "pads short base line" do
      result = Overlay.composite_line("abc", "X", 5, 1, 10)
      stripped = String.replace(result, ~r/\e\[[0-9;]*m/, "")
      assert String.at(stripped, 5) == "X"
    end

    test "pads short overlay" do
      result = Overlay.composite_line("0123456789", "A", 3, 3, 10)
      stripped = String.replace(result, ~r/\e\[[0-9;]*m/, "")
      assert String.at(stripped, 3) == "A"
      assert String.at(stripped, 4) == " "
      assert String.at(stripped, 5) == " "
      assert String.at(stripped, 6) == "6"
    end
  end
end
