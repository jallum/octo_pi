defmodule OctoPi.TUI.Components.DynamicBorderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.DynamicBorder
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  describe "render/2" do
    test "returns a single line" do
      border = DynamicBorder.new(@theme)
      lines = DynamicBorder.render(border, 40)
      assert length(lines) == 1
    end

    test "line contains box-drawing horizontal character" do
      border = DynamicBorder.new(@theme)
      [line] = DynamicBorder.render(border, 10)
      assert line =~ "─"
    end

    test "uses border_muted theme color" do
      border = DynamicBorder.new(@theme)
      [line] = DynamicBorder.render(border, 10)
      ansi = Theme.get_fg_ansi(@theme, :border_muted)
      assert line =~ ansi
    end

    test "visible width matches requested width" do
      border = DynamicBorder.new(@theme)
      [line] = DynamicBorder.render(border, 60)
      stripped = strip_ansi(line)
      assert String.length(stripped) == 60
    end

    test "width of 1 produces single character" do
      border = DynamicBorder.new(@theme)
      [line] = DynamicBorder.render(border, 1)
      stripped = strip_ansi(line)
      assert stripped == "─"
    end
  end

  defp strip_ansi(str) do
    Regex.replace(~r/\e\[[0-9;]*m/, str, "")
  end
end
