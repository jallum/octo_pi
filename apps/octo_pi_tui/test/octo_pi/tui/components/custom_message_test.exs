defmodule OctoPi.TUI.Components.CustomMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.CustomMessage
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/4" do
    test "creates with custom type and content" do
      msg = CustomMessage.new("notification", "Hello world", @theme)
      assert msg.custom_type == "notification"
      assert msg.content == "Hello world"
    end

    test "accepts custom renderer" do
      renderer = fn _msg, _opts, _theme -> ["custom line"] end
      msg = CustomMessage.new("test", "content", @theme, renderer: renderer)
      assert msg.renderer
    end
  end

  # ── Default rendering ──────────────────────────────────────────

  describe "render/2 default" do
    test "shows custom type label" do
      msg = CustomMessage.new("notification", "Alert!", @theme)
      lines = CustomMessage.render(msg, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[notification]"))
    end

    test "shows content text" do
      msg = CustomMessage.new("info", "Important message here", @theme)
      lines = CustomMessage.render(msg, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Important message here"))
    end

    test "renders in styled box" do
      msg = CustomMessage.new("info", "boxed", @theme)
      lines = CustomMessage.render(msg, 60)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  # ── Custom renderer ────────────────────────────────────────────

  describe "render/2 with custom renderer" do
    test "delegates to custom renderer" do
      renderer = fn msg, _opts, _theme ->
        ["[CUSTOM] #{msg.content}"]
      end

      msg = CustomMessage.new("test", "hello", @theme, renderer: renderer)
      lines = CustomMessage.render(msg, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[CUSTOM] hello"))
    end

    test "passes expanded option to renderer" do
      renderer = fn _msg, opts, _theme ->
        if opts[:expanded], do: ["[EXPANDED]"], else: ["[COLLAPSED]"]
      end

      msg = CustomMessage.new("test", "x", @theme, renderer: renderer)
      collapsed = msg |> CustomMessage.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(collapsed, &(&1 =~ "[COLLAPSED]"))

      expanded =
        %{msg | expanded: true}
        |> CustomMessage.render(60)
        |> Enum.map(&strip_ansi/1)

      assert Enum.any?(expanded, &(&1 =~ "[EXPANDED]"))
    end

    test "falls back to default on renderer error" do
      renderer = fn _msg, _opts, _theme -> raise "boom" end

      msg = CustomMessage.new("fallback", "safe content", @theme, renderer: renderer)
      lines = CustomMessage.render(msg, 60)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[fallback]"))
      assert Enum.any?(stripped, &(&1 =~ "safe content"))
    end
  end

  # ── Expand/collapse ────────────────────────────────────────────

  describe "expanded" do
    test "toggle_expanded flips state" do
      msg = CustomMessage.new("test", "x", @theme)
      assert msg.expanded == false
      msg = CustomMessage.toggle_expanded(msg)
      assert msg.expanded == true
    end
  end
end
