defmodule OctoPi.TUI.Components.SettingsSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SettingsSelector
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp key(name), do: %Key{key: name}

  defp press(selector, key_spec) do
    case SettingsSelector.handle_key(selector, key_spec) do
      {new, _events} -> new
      new -> new
    end
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/2" do
    test "creates with default settings" do
      sel = SettingsSelector.new(@theme)
      assert sel.selected == 0
      assert is_list(sel.items)
      assert sel.items != []
    end

    test "accepts current settings" do
      sel = SettingsSelector.new(@theme, thinking_level: :verbose, theme: :light)
      setting = Enum.find(sel.items, &(&1.key == :thinking_level))
      assert setting.value == :verbose
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    test "Down moves selection" do
      sel = @theme |> SettingsSelector.new() |> press(key(:down))
      assert sel.selected == 1
    end

    test "Up wraps" do
      sel = @theme |> SettingsSelector.new() |> press(key(:up))
      assert sel.selected == length(sel.items) - 1
    end
  end

  # ── Value cycling ──────────────────────────────────────────────

  describe "value cycling" do
    test "Enter cycles to next value" do
      sel = SettingsSelector.new(@theme, thinking_level: :off)
      thinking_idx = Enum.find_index(sel.items, &(&1.key == :thinking_level))
      sel = %{sel | selected: thinking_idx}
      {sel, events} = SettingsSelector.handle_key(sel, key(:enter))
      setting = Enum.find(sel.items, &(&1.key == :thinking_level))
      assert setting.value != :off
      assert [{:setting_changed, :thinking_level, _}] = events
    end

    test "Escape cancels" do
      sel = SettingsSelector.new(@theme)
      {_sel, events} = SettingsSelector.handle_key(sel, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2" do
    test "shows setting labels" do
      sel = SettingsSelector.new(@theme)
      lines = sel |> SettingsSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "Theme"))
      assert Enum.any?(lines, &(&1 =~ "Thinking"))
    end

    test "shows current values" do
      sel = SettingsSelector.new(@theme, thinking_level: :verbose)
      lines = sel |> SettingsSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "verbose"))
    end

    test "highlights selected item" do
      sel = SettingsSelector.new(@theme)
      lines = SettingsSelector.render(sel, 60)
      assert Enum.any?(lines, &(&1 =~ "\e[7m"))
    end
  end
end
