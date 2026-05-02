defmodule OctoPi.TUI.Components.CompactionSummaryMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.CompactionSummaryMessage, as: Msg
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: Component
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @theme Theme.load_builtin(:dark, :truecolor)

  @summary "Compacted 5 turns. Key decisions: foo bar baz."

  defp ctx(width), do: %RenderContext{theme: @theme, width: width}

  defp msg(tokens_before \\ 50_000) do
    Msg.new(@summary, tokens_before, 0)
  end

  defp render_lines(comp, width \\ 80) do
    {_, %VDOM.VLines{lines: lines}, nil} = Component.render(comp, ctx(width))
    lines
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp render_stripped(comp, width \\ 80) do
    comp |> render_lines(width) |> Enum.map(&strip_ansi/1)
  end

  # ── Construction ───────────────────────────────────────────────────────────

  describe "new/3" do
    test "starts collapsed" do
      comp = Component.new(msg())
      assert comp.expanded == false
    end

    test "stores message" do
      m = msg()
      comp = Component.new(m)
      assert comp.message == m
    end
  end

  # ── toggle_expanded/1 ─────────────────────────────────────────────────────

  describe "toggle_expanded/1" do
    test "flips false → true" do
      comp = Component.new(msg())
      assert Component.toggle_expanded(comp).expanded == true
    end

    test "flips true → false" do
      comp = %{Component.new(msg()) | expanded: true}
      assert Component.toggle_expanded(comp).expanded == false
    end
  end

  # ── render/2 — collapsed ──────────────────────────────────────────────────

  describe "render/2 collapsed" do
    test "shows [compaction] label" do
      lines = render_stripped(Component.new(msg()))
      assert Enum.any?(lines, &(&1 =~ "[compaction]"))
    end

    test "shows token count" do
      lines = render_stripped(Component.new(msg(50_000)))
      assert Enum.any?(lines, &(&1 =~ "50,000"))
    end

    test "shows expand keybinding hint" do
      lines = render_stripped(Component.new(msg()))
      assert Enum.any?(lines, &(&1 =~ "to expand"))
    end

    test "shows ctrl+o as default expand key" do
      lines = render_stripped(Component.new(msg()))
      assert Enum.any?(lines, &(&1 =~ "ctrl+o"))
    end

    test "does not show summary text" do
      lines = render_stripped(Component.new(msg()))
      refute Enum.any?(lines, &(&1 =~ @summary))
    end

    test "applies background color" do
      lines = msg() |> Component.new() |> render_lines()
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "first line is blank separator" do
      lines = msg() |> Component.new() |> render_lines()
      assert hd(lines) == ""
    end
  end

  # ── render/2 — expanded ───────────────────────────────────────────────────

  describe "render/2 expanded" do
    defp expanded_comp, do: %{Component.new(msg()) | expanded: true}

    test "shows [compaction] label" do
      lines = render_stripped(expanded_comp())
      assert Enum.any?(lines, &(&1 =~ "[compaction]"))
    end

    test "shows token count in header" do
      lines = 12_345 |> msg() |> Component.new() |> Component.toggle_expanded() |> render_stripped()
      assert Enum.any?(lines, &(&1 =~ "12,345"))
    end

    test "shows summary text" do
      lines = render_stripped(expanded_comp())
      joined = Enum.join(lines, "\n")
      assert joined =~ "Compacted 5 turns"
    end

    test "does not show expand hint" do
      lines = render_stripped(expanded_comp())
      refute Enum.any?(lines, &(&1 =~ "to expand"))
    end

    test "applies background color" do
      lines = render_lines(expanded_comp())
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  # ── format_number (via render) ────────────────────────────────────────────

  describe "token number formatting" do
    test "small number has no commas" do
      lines = render_stripped(Component.new(msg(999)))
      assert Enum.any?(lines, &(&1 =~ "999 tokens"))
    end

    test "thousands get comma-separated" do
      lines = render_stripped(Component.new(msg(1_234_567)))
      assert Enum.any?(lines, &(&1 =~ "1,234,567"))
    end
  end
end
