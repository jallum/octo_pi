defmodule OctoPi.TUI.ThemeTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Theme

  @esc "\e"

  # ── Color utilities ──────────────────────────────────────────────

  describe "hex_to_rgb/1" do
    test "parses 6-digit hex with hash" do
      assert Theme.hex_to_rgb("#ff8800") == {255, 136, 0}
    end

    test "parses 6-digit hex without hash" do
      assert Theme.hex_to_rgb("00d7ff") == {0, 215, 255}
    end

    test "is case-insensitive" do
      assert Theme.hex_to_rgb("#AbCdEf") == {171, 205, 239}
    end

    test "raises on invalid hex" do
      assert_raise ArgumentError, fn -> Theme.hex_to_rgb("#zzzzzz") end
      assert_raise ArgumentError, fn -> Theme.hex_to_rgb("#fff") end
    end
  end

  describe "rgb_to_256/3" do
    test "pure red maps to cube index" do
      assert Theme.rgb_to_256(255, 0, 0) == 196
    end

    test "pure green maps to cube index" do
      assert Theme.rgb_to_256(0, 255, 0) == 46
    end

    test "pure blue maps to cube index" do
      assert Theme.rgb_to_256(0, 0, 255) == 21
    end

    test "near-neutral maps to grayscale" do
      idx = Theme.rgb_to_256(128, 128, 128)
      assert idx in 232..255
    end

    test "saturated color prefers cube over gray" do
      idx = Theme.rgb_to_256(138, 190, 183)
      assert idx in 16..231
    end
  end

  # ── ANSI escape generation ──────────────────────────────────────

  describe "fg_ansi/2" do
    test "truecolor hex" do
      assert Theme.fg_ansi("#ff0000", :truecolor) == "#{@esc}[38;2;255;0;0m"
    end

    test "256-color hex" do
      ansi = Theme.fg_ansi("#ff0000", :"256color")
      assert ansi == "#{@esc}[38;5;196m"
    end

    test "256-color index" do
      assert Theme.fg_ansi(42, :truecolor) == "#{@esc}[38;5;42m"
    end

    test "empty string resets foreground" do
      assert Theme.fg_ansi("", :truecolor) == "#{@esc}[39m"
    end
  end

  describe "bg_ansi/2" do
    test "truecolor hex" do
      assert Theme.bg_ansi("#00ff00", :truecolor) == "#{@esc}[48;2;0;255;0m"
    end

    test "256-color hex" do
      assert Theme.bg_ansi("#00ff00", :"256color") == "#{@esc}[48;5;46m"
    end

    test "empty string resets background" do
      assert Theme.bg_ansi("", :truecolor) == "#{@esc}[49m"
    end
  end

  # ── Variable resolution ─────────────────────────────────────────

  describe "resolve_color/2" do
    test "hex values pass through" do
      assert Theme.resolve_color("#ff0000", %{}) == "#ff0000"
    end

    test "empty string passes through" do
      assert Theme.resolve_color("", %{}) == ""
    end

    test "integer passes through" do
      assert Theme.resolve_color(42, %{}) == 42
    end

    test "resolves single-level variable" do
      vars = %{"accent" => "#8abeb7"}
      assert Theme.resolve_color("accent", vars) == "#8abeb7"
    end

    test "resolves chained variables" do
      vars = %{"primary" => "accent", "accent" => "#8abeb7"}
      assert Theme.resolve_color("primary", vars) == "#8abeb7"
    end

    test "raises on circular reference" do
      vars = %{"a" => "b", "b" => "a"}
      assert_raise ArgumentError, ~r/[Cc]ircular/, fn -> Theme.resolve_color("a", vars) end
    end

    test "raises on missing variable" do
      assert_raise ArgumentError, ~r/not found/, fn ->
        Theme.resolve_color("missing", %{})
      end
    end
  end

  # ── JSON loading ────────────────────────────────────────────────

  describe "from_json/2" do
    test "loads dark theme from bundled JSON" do
      path = Path.join(:code.priv_dir(:octo_pi_tui), "themes/dark.json")
      json = Jason.decode!(File.read!(path))
      theme = Theme.from_json(json, :truecolor)

      assert theme.name == "dark"
      assert is_map(theme.fg_colors)
      assert is_map(theme.bg_colors)
      assert map_size(theme.fg_colors) > 0
      assert map_size(theme.bg_colors) > 0
    end

    test "loads light theme from bundled JSON" do
      path = Path.join(:code.priv_dir(:octo_pi_tui), "themes/light.json")
      json = Jason.decode!(File.read!(path))
      theme = Theme.from_json(json, :truecolor)

      assert theme.name == "light"
    end

    test "resolves variable references in colors" do
      json = %{
        "name" => "test",
        "vars" => %{"myblue" => "#0000ff"},
        "colors" => minimal_colors(%{"accent" => "myblue"})
      }

      theme = Theme.from_json(json, :truecolor)
      assert theme.fg_colors[:accent] == "#{@esc}[38;2;0;0;255m"
    end
  end

  # ── Built-in theme loading ──────────────────────────────────────

  describe "load_builtin/2" do
    test "loads dark theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      assert theme.name == "dark"
    end

    test "loads light theme" do
      theme = Theme.load_builtin(:light, :truecolor)
      assert theme.name == "light"
    end

    test "raises on unknown builtin" do
      assert_raise ArgumentError, fn -> Theme.load_builtin(:neon, :truecolor) end
    end
  end

  # ── Fluent API ──────────────────────────────────────────────────

  describe "fg/3" do
    test "wraps text with foreground color and reset" do
      theme = Theme.load_builtin(:dark, :truecolor)
      result = Theme.fg(theme, :error, "oops")
      assert result =~ ~r/\e\[38;2;\d+;\d+;\d+moops\e\[39m/
    end

    test "raises on unknown color key" do
      theme = Theme.load_builtin(:dark, :truecolor)
      assert_raise ArgumentError, fn -> Theme.fg(theme, :nonexistent, "x") end
    end
  end

  describe "bg/3" do
    test "wraps text with background color and reset" do
      theme = Theme.load_builtin(:dark, :truecolor)
      result = Theme.bg(theme, :selected_bg, "hi")
      assert result =~ ~r/\e\[48;2;\d+;\d+;\d+mhi\e\[49m/
    end

    test "raises on unknown bg key" do
      theme = Theme.load_builtin(:dark, :truecolor)
      assert_raise ArgumentError, fn -> Theme.bg(theme, :nonexistent, "x") end
    end
  end

  describe "text formatting" do
    test "bold wraps with ANSI bold" do
      assert Theme.bold("hi") == "#{@esc}[1mhi#{@esc}[22m"
    end

    test "italic wraps with ANSI italic" do
      assert Theme.italic("hi") == "#{@esc}[3mhi#{@esc}[23m"
    end

    test "underline wraps with ANSI underline" do
      assert Theme.underline("hi") == "#{@esc}[4mhi#{@esc}[24m"
    end

    test "inverse wraps with ANSI inverse" do
      assert Theme.inverse("hi") == "#{@esc}[7mhi#{@esc}[27m"
    end

    test "strikethrough wraps with ANSI strikethrough" do
      assert Theme.strikethrough("hi") == "#{@esc}[9mhi#{@esc}[29m"
    end
  end

  # ── Raw ANSI accessors ──────────────────────────────────────────

  describe "get_fg_ansi/2" do
    test "returns raw ANSI escape for a color key" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ansi = Theme.get_fg_ansi(theme, :accent)
      assert ansi =~ ~r/\e\[38;2;\d+;\d+;\d+m/
    end
  end

  describe "get_bg_ansi/2" do
    test "returns raw ANSI escape for a bg key" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ansi = Theme.get_bg_ansi(theme, :selected_bg)
      assert ansi =~ ~r/\e\[48;2;\d+;\d+;\d+m/
    end
  end

  # ── Color mode detection ────────────────────────────────────────

  describe "detect_color_mode/0" do
    test "returns an atom" do
      mode = Theme.detect_color_mode()
      assert mode in [:truecolor, :"256color"]
    end
  end

  # ── Available themes ────────────────────────────────────────────

  describe "available_themes/0" do
    test "includes dark and light" do
      themes = Theme.available_themes()
      assert "dark" in themes
      assert "light" in themes
    end
  end

  # ── All color keys ──────────────────────────────────────────────

  describe "color_keys/0 and bg_keys/0" do
    test "color_keys returns all foreground color atoms" do
      keys = Theme.color_keys()
      assert :accent in keys
      assert :error in keys
      assert :md_heading in keys
      assert :syntax_keyword in keys
      assert :thinking_high in keys
      assert :bash_mode in keys
    end

    test "bg_keys returns all background color atoms" do
      keys = Theme.bg_keys()
      assert :selected_bg in keys
      assert :user_message_bg in keys
      assert :tool_pending_bg in keys
    end

    test "dark theme has all color keys populated" do
      theme = Theme.load_builtin(:dark, :truecolor)

      for key <- Theme.color_keys() do
        assert Map.has_key?(theme.fg_colors, key),
               "dark theme missing fg color: #{inspect(key)}"
      end

      for key <- Theme.bg_keys() do
        assert Map.has_key?(theme.bg_colors, key),
               "dark theme missing bg color: #{inspect(key)}"
      end
    end

    test "light theme has all color keys populated" do
      theme = Theme.load_builtin(:light, :truecolor)

      for key <- Theme.color_keys() do
        assert Map.has_key?(theme.fg_colors, key),
               "light theme missing fg color: #{inspect(key)}"
      end

      for key <- Theme.bg_keys() do
        assert Map.has_key?(theme.bg_colors, key),
               "light theme missing bg color: #{inspect(key)}"
      end
    end
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp minimal_colors(overrides \\ %{}) do
    base =
      Map.new(Theme.color_keys(), fn key ->
        {Theme.color_key_to_json(key), "#000000"}
      end)

    bg =
      Map.new(Theme.bg_keys(), fn key ->
        {Theme.color_key_to_json(key), "#000000"}
      end)

    Map.merge(base, bg) |> Map.merge(overrides)
  end
end
