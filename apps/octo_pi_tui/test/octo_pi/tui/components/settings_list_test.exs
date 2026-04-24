defmodule OctoPi.TUI.Components.SettingsListTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SettingsList
  alias OctoPi.TUI.Components.SettingsList.Item
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp key(name), do: %Key{key: name}

  defp press(list, key_spec) do
    case SettingsList.handle_key(list, key_spec) do
      {new, _events} -> new
      new -> new
    end
  end

  defp radio_items do
    [
      Item.radio("size", "Size", ["small", "medium", "large"], "medium"),
      Item.radio("color", "Color", ["red", "blue", "green"], "red")
    ]
  end

  defp checkbox_items do
    [
      Item.checkbox("opt_a", "Option A", true),
      Item.checkbox("opt_b", "Option B", false),
      Item.checkbox("opt_c", "Option C", true)
    ]
  end

  defp toggle_items do
    [
      Item.toggle("dark_mode", "Dark Mode", true),
      Item.toggle("sound", "Sound", false)
    ]
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/2" do
    test "creates with items and theme" do
      list = SettingsList.new(radio_items(), @theme)
      assert list.selected == 0
      assert length(list.items) == 2
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    test "Down moves selection" do
      list = SettingsList.new(radio_items(), @theme) |> press(key(:down))
      assert list.selected == 1
    end

    test "Up wraps" do
      list = SettingsList.new(radio_items(), @theme) |> press(key(:up))
      assert list.selected == 1
    end

    test "Down wraps" do
      list =
        SettingsList.new(radio_items(), @theme)
        |> press(key(:down))
        |> press(key(:down))

      assert list.selected == 0
    end
  end

  # ── Radio cycling ──────────────────────────────────────────────

  describe "radio items" do
    test "Enter cycles to next value" do
      list = SettingsList.new(radio_items(), @theme)
      {list, events} = SettingsList.handle_key(list, key(:enter))
      item = Enum.find(list.items, &(&1.id == "size"))
      assert item.value == "large"
      assert [{:setting_changed, "size", "large"}] = events
    end

    test "Enter wraps at end of options" do
      items = [Item.radio("x", "X", ["a", "b"], "b")]
      list = SettingsList.new(items, @theme)
      {list, _} = SettingsList.handle_key(list, key(:enter))
      assert hd(list.items).value == "a"
    end

    test "Space also cycles" do
      list = SettingsList.new(radio_items(), @theme)
      {list, events} = SettingsList.handle_key(list, %Key{key: ?\s})
      item = Enum.find(list.items, &(&1.id == "size"))
      assert item.value == "large"
      assert [{:setting_changed, "size", "large"}] = events
    end
  end

  # ── Checkbox toggling ──────────────────────────────────────────

  describe "checkbox items" do
    test "Enter toggles checked state" do
      list = SettingsList.new(checkbox_items(), @theme)
      {list, events} = SettingsList.handle_key(list, key(:enter))
      item = Enum.find(list.items, &(&1.id == "opt_a"))
      assert item.value == false
      assert [{:setting_changed, "opt_a", false}] = events
    end

    test "toggling false to true" do
      list = SettingsList.new(checkbox_items(), @theme) |> press(key(:down))
      {list, events} = SettingsList.handle_key(list, key(:enter))
      item = Enum.find(list.items, &(&1.id == "opt_b"))
      assert item.value == true
      assert [{:setting_changed, "opt_b", true}] = events
    end
  end

  # ── Toggle items ───────────────────────────────────────────────

  describe "toggle items" do
    test "Enter flips toggle" do
      list = SettingsList.new(toggle_items(), @theme)
      {list, events} = SettingsList.handle_key(list, key(:enter))
      item = Enum.find(list.items, &(&1.id == "dark_mode"))
      assert item.value == false
      assert [{:setting_changed, "dark_mode", false}] = events
    end
  end

  # ── Escape ─────────────────────────────────────────────────────

  describe "escape" do
    test "Escape cancels" do
      list = SettingsList.new(radio_items(), @theme)
      {_list, events} = SettingsList.handle_key(list, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2" do
    test "radio items show current value" do
      list = SettingsList.new(radio_items(), @theme)
      lines = list |> SettingsList.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "medium"))
    end

    test "checkbox items show check indicator" do
      list = SettingsList.new(checkbox_items(), @theme)
      lines = list |> SettingsList.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "☑"))
      assert Enum.any?(lines, &(&1 =~ "☐"))
    end

    test "toggle items show on/off" do
      list = SettingsList.new(toggle_items(), @theme)
      lines = list |> SettingsList.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "on"))
      assert Enum.any?(lines, &(&1 =~ "off"))
    end

    test "selected item is highlighted" do
      list = SettingsList.new(radio_items(), @theme)
      lines = SettingsList.render(list, 60)
      assert Enum.any?(lines, &(&1 =~ "\e[7m"))
    end
  end

  # ── Update value ───────────────────────────────────────────────

  describe "update_value/3" do
    test "updates item by id" do
      list = SettingsList.new(radio_items(), @theme)
      list = SettingsList.update_value(list, "size", "small")
      item = Enum.find(list.items, &(&1.id == "size"))
      assert item.value == "small"
    end
  end
end
