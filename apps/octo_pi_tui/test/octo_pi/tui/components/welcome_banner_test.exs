defmodule OctoPi.TUI.Components.WelcomeBannerTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.WelcomeBanner
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  describe "new/2" do
    test "creates a compact banner" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      assert banner.expanded == false
    end
  end

  describe "render/2 — compact" do
    test "shows product name and version" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      lines = WelcomeBanner.render(banner, 80)
      text = Enum.join(lines, "\n")
      assert text =~ "octo_pi"
    end

    test "shows inline keybinding hints" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      lines = WelcomeBanner.render(banner, 80)
      text = lines |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "escape interrupt"
      assert text =~ "/ commands"
    end

    test "compact hints line fits within 70 visible characters" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      [_title, hints | _] = WelcomeBanner.render(banner, 80)
      visible = String.replace(hints, ~r/\e\[[0-9;]*m/, "")
      assert String.length(visible) <= 70
    end

    test "compact render returns exactly 2 lines" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      assert length(WelcomeBanner.render(banner, 80)) == 2
    end
  end

  describe "render/2 — expanded" do
    test "shows keybinding hints" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6", expanded: true)
      lines = WelcomeBanner.render(banner, 80)
      text = Enum.join(lines, "\n")
      assert text =~ "Esc"
      assert text =~ "commands"
    end

    test "has more lines than compact" do
      compact = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      expanded = WelcomeBanner.new(@theme, model: "claude-opus-4-6", expanded: true)

      assert length(WelcomeBanner.render(expanded, 80)) >
               length(WelcomeBanner.render(compact, 80))
    end
  end

  describe "handle_key/2" do
    test "? toggles expanded state" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      refute banner.expanded
      toggled = WelcomeBanner.handle_key(banner, %Key{key: ??})
      assert toggled.expanded
      toggled2 = WelcomeBanner.handle_key(toggled, %Key{key: ??})
      refute toggled2.expanded
    end

    test "other keys pass through" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6")
      result = WelcomeBanner.handle_key(banner, %Key{key: ?a})
      assert result == banner
    end
  end

  describe "quiet mode" do
    test "renders empty when quiet" do
      banner = WelcomeBanner.new(@theme, model: "claude-opus-4-6", quiet: true)
      assert WelcomeBanner.render(banner, 80) == []
    end
  end
end
