defmodule OctoPi.TUI.Components.CompactionSummaryMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.CompactionSummaryMessage, as: Msg
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: Component
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  @summary "Compacted 5 turns. Key decisions: foo bar baz."

  defp msg(tokens_before \\ 50_000) do
    Msg.new(@summary, tokens_before, 0)
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp render_stripped(comp, width \\ 80) do
    comp |> Component.render(width) |> Enum.map(&strip_ansi/1)
  end

  # ── Construction ───────────────────────────────────────────────────────────

  describe "new/3" do
    test "starts collapsed" do
      comp = Component.new(msg(), @theme)
      assert comp.expanded == false
    end

    test "stores message and theme" do
      m = msg()
      comp = Component.new(m, @theme)
      assert comp.message == m
      assert comp.theme == @theme
    end
  end

  # ── toggle_expanded/1 ─────────────────────────────────────────────────────

  describe "toggle_expanded/1" do
    test "flips false → true" do
      comp = Component.new(msg(), @theme)
      assert Component.toggle_expanded(comp).expanded == true
    end

    test "flips true → false" do
      comp = %{Component.new(msg(), @theme) | expanded: true}
      assert Component.toggle_expanded(comp).expanded == false
    end
  end

  # ── render/2 — collapsed ──────────────────────────────────────────────────

  describe "render/2 collapsed" do
    test "shows [compaction] label" do
      lines = render_stripped(Component.new(msg(), @theme))
      assert Enum.any?(lines, &(&1 =~ "[compaction]"))
    end

    test "shows token count" do
      lines = render_stripped(Component.new(msg(50_000), @theme))
      assert Enum.any?(lines, &(&1 =~ "50,000"))
    end

    test "shows expand keybinding hint" do
      lines = render_stripped(Component.new(msg(), @theme))
      assert Enum.any?(lines, &(&1 =~ "to expand"))
    end

    test "shows ctrl+o as default expand key" do
      lines = render_stripped(Component.new(msg(), @theme))
      assert Enum.any?(lines, &(&1 =~ "ctrl+o"))
    end

    test "does not show summary text" do
      lines = render_stripped(Component.new(msg(), @theme))
      refute Enum.any?(lines, &(&1 =~ @summary))
    end

    test "applies background color" do
      lines = msg() |> Component.new(@theme) |> Component.render(80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "first line is blank separator" do
      lines = msg() |> Component.new(@theme) |> Component.render(80)
      assert hd(lines) == ""
    end
  end

  # ── render/2 — expanded ───────────────────────────────────────────────────

  describe "render/2 expanded" do
    defp expanded_comp, do: %{Component.new(msg(), @theme) | expanded: true}

    test "shows [compaction] label" do
      lines = render_stripped(expanded_comp())
      assert Enum.any?(lines, &(&1 =~ "[compaction]"))
    end

    test "shows token count in header" do
      lines = 12_345 |> msg() |> Component.new(@theme) |> Component.toggle_expanded() |> render_stripped()
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
      lines = Component.render(expanded_comp(), 80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  # ── format_number (via render) ────────────────────────────────────────────

  describe "token number formatting" do
    test "small number has no commas" do
      lines = render_stripped(Component.new(msg(999), @theme))
      assert Enum.any?(lines, &(&1 =~ "999 tokens"))
    end

    test "thousands get comma-separated" do
      lines = render_stripped(Component.new(msg(1_234_567), @theme))
      assert Enum.any?(lines, &(&1 =~ "1,234,567"))
    end
  end
end
