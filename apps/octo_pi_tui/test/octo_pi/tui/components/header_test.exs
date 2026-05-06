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

    test "compact hints line fits within 80 visible characters" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      [_title, hints | _] = render_lines(banner)
      visible = String.replace(hints, ~r/\e\[[0-9;]*m/, "")
      assert String.length(visible) <= 80
    end

    test "compact render returns exactly 6 lines (title + hints + empty + help + pi + empty)" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      assert length(render_lines(banner)) == 6
    end

    test "key and description segments use distinct color tokens" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      [_title, hints | _] = render_lines(banner)
      # dim ANSI code (\e[2m) precedes key text
      assert hints =~ "\e[2m"
    end
  end

  describe "render/2 — expanded" do
    test "shows keybinding hints" do
      banner = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      text = banner |> render_lines() |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "escape"
      assert text =~ "commands"
    end

    test "has more lines than compact" do
      compact = Header.new(@theme, model: "claude-opus-4-6")
      expanded = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      assert length(render_lines(expanded)) > length(render_lines(compact))
    end

    test "expanded shows all 19 hint entries" do
      banner = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      text = banner |> render_lines() |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "to interrupt"
      assert text =~ "to clear"
      assert text =~ "to exit"
      assert text =~ "to suspend"
      assert text =~ "to delete to end"
      assert text =~ "to cycle thinking level"
      assert text =~ "to cycle models"
      assert text =~ "to select model"
      assert text =~ "to expand tools"
      assert text =~ "to expand thinking"
      assert text =~ "for external editor"
      assert text =~ "for commands"
      assert text =~ "to run bash"
      assert text =~ "to queue follow-up"
      assert text =~ "to edit all queued messages"
      assert text =~ "to paste image"
      assert text =~ "drop files"
      assert text =~ "to attach"
    end

    test "toggle is ctrl+o not ?" do
      banner = Header.new(@theme, model: "claude-opus-4-6", expanded: true)
      text = banner |> render_lines() |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "ctrl+o"
      refute text =~ "toggle this banner"
    end
  end

  describe "handle_key/2" do
    test "all keys pass through without changing state" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      result = Header.handle_key(banner, %Key{key: ?a})
      assert result == banner
    end

    test "ctrl+o does not toggle via header (toggle is owned by interactive.ex)" do
      banner = Header.new(@theme, model: "claude-opus-4-6")
      refute banner.expanded
      result = Header.handle_key(banner, %Key{key: ?o, modifiers: [:ctrl]})
      refute result.expanded
    end
  end

  describe "quiet mode" do
    test "renders empty when quiet" do
      banner = Header.new(@theme, model: "claude-opus-4-6", quiet: true)
      assert render_lines(banner) == []
    end
  end
end
