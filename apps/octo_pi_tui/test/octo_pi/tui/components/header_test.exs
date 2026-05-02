defmodule OctoPi.TUI.Components.HeaderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Header
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)
  @ctx %RenderContext{theme: @theme, width: 80}

  defp render_lines(banner), do: banner |> Header.render(@ctx) |> elem(1) |> then(& &1.lines)

  describe "new/2" do
    test "creates a compact banner" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      assert banner.expanded == false
    end
  end

  describe "render/2 — compact" do
    test "shows product name and version" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      text = banner |> render_lines() |> Enum.join("\n")
      assert text =~ "octo_pi"
    end

    test "shows inline keybinding hints" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      text = banner |> render_lines() |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "escape interrupt"
      assert text =~ "/ commands"
    end

    test "compact hints line fits within 70 visible characters" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      [_title, hints | _] = render_lines(banner)
      visible = String.replace(hints, ~r/\e\[[0-9;]*m/, "")
      assert String.length(visible) <= 70
    end

    test "compact render returns exactly 3 lines" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      assert length(render_lines(banner)) == 3
    end
  end

  describe "render/2 — expanded" do
    test "shows keybinding hints" do
      banner = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      text = banner |> render_lines() |> Enum.join("\n")
      assert text =~ "Esc"
      assert text =~ "commands"
    end

    test "has more lines than compact" do
      compact = Header.new(@theme, model: "claude-opus-4-6")
      expanded = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      assert length(render_lines(expanded)) > length(render_lines(compact))
    end

    test "expanded banner does not reference Ctrl+O (no handler exists)" do
      banner = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      text = banner |> render_lines() |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      refute text =~ "Ctrl+O"
      refute text =~ "ctrl+o"
    end
  end

  describe "handle_key/2" do
    test "? toggles expanded state" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      refute banner.expanded
      toggled = Header.handle_key(banner, %Key{key: ??})
      assert toggled.expanded
      toggled2 = Header.handle_key(toggled, %Key{key: ??})
      refute toggled2.expanded
    end

    test "other keys pass through" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      result = Header.handle_key(banner, %Key{key: ?a})
      assert result == banner
    end
  end

  describe "quiet mode" do
    test "renders empty when quiet" do
      banner = Header.new(@theme, model: "claude-opus-4-6", quiet: true)
      assert render_lines(banner) == []
    end
  end
end
