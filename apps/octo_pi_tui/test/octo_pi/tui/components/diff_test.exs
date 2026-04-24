defmodule OctoPi.TUI.Components.DiffTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Diff
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  # ── Line parsing ──────────────────────────────────────────────

  describe "render_diff/2 line types" do
    test "context lines are rendered with dim color" do
      diff = " 10 unchanged line"
      lines = Diff.render_diff(diff, @theme)
      assert length(lines) == 1
      stripped = strip_ansi(hd(lines))
      assert stripped =~ "10"
      assert stripped =~ "unchanged line"
    end

    test "added lines are rendered in green" do
      diff = "+15 new code"
      lines = Diff.render_diff(diff, @theme)
      assert length(lines) == 1
      stripped = strip_ansi(hd(lines))
      assert stripped =~ "+15"
      assert stripped =~ "new code"
      assert hd(lines) =~ Theme.get_fg_ansi(@theme, :tool_diff_added)
    end

    test "removed lines are rendered in red" do
      diff = "-12 old code"
      lines = Diff.render_diff(diff, @theme)
      assert length(lines) == 1
      stripped = strip_ansi(hd(lines))
      assert stripped =~ "-12"
      assert stripped =~ "old code"
      assert hd(lines) =~ Theme.get_fg_ansi(@theme, :tool_diff_removed)
    end
  end

  # ── Multi-line diffs ──────────────────────────────────────────

  describe "render_diff/2 multi-line" do
    test "handles mixed context, added, removed lines" do
      diff = """
       10 context
      -11 removed
      +11 added
       12 context\
      """

      lines = Diff.render_diff(diff, @theme)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert length(stripped) == 4
      assert Enum.at(stripped, 0) =~ "context"
      assert Enum.at(stripped, 1) =~ "removed"
      assert Enum.at(stripped, 2) =~ "added"
      assert Enum.at(stripped, 3) =~ "context"
    end

    test "multi-line removal followed by multi-line addition" do
      diff = """
      -10 old_a
      -11 old_b
      +10 new_a
      +11 new_b\
      """

      lines = Diff.render_diff(diff, @theme)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert length(stripped) == 4
      assert Enum.at(stripped, 0) =~ "old_a"
      assert Enum.at(stripped, 1) =~ "old_b"
      assert Enum.at(stripped, 2) =~ "new_a"
      assert Enum.at(stripped, 3) =~ "new_b"
    end
  end

  # ── Intra-line diffing ────────────────────────────────────────

  describe "render_diff/2 intra-line" do
    test "single-line modification highlights changed words" do
      diff = """
      -10 hello world
      +10 hello universe\
      """

      lines = Diff.render_diff(diff, @theme)
      assert length(lines) == 2
      assert Enum.at(lines, 1) =~ "\e[7m"
    end

    test "no intra-line diff for multi-line changes" do
      diff = """
      -10 line_a
      -11 line_b
      +10 line_c\
      """

      lines = Diff.render_diff(diff, @theme)
      refute Enum.any?(lines, &(&1 =~ "\e[7m"))
    end
  end

  # ── Tab replacement ───────────────────────────────────────────

  describe "render_diff/2 tabs" do
    test "replaces tabs with spaces" do
      diff = "+5 \tindented"
      lines = Diff.render_diff(diff, @theme)
      stripped = strip_ansi(hd(lines))
      refute stripped =~ "\t"
      assert stripped =~ "   indented"
    end
  end

  # ── Non-diff lines ────────────────────────────────────────────

  describe "render_diff/2 non-diff lines" do
    test "hunk headers pass through as context" do
      diff = "@@ -10,5 +10,6 @@"
      lines = Diff.render_diff(diff, @theme)
      stripped = strip_ansi(hd(lines))
      assert stripped =~ "@@"
    end

    test "file headers pass through as context" do
      diff = "--- a/lib/foo.ex"
      lines = Diff.render_diff(diff, @theme)
      stripped = strip_ansi(hd(lines))
      assert stripped =~ "lib/foo.ex"
    end
  end

  # ── Empty input ───────────────────────────────────────────────

  describe "render_diff/2 empty" do
    test "empty string returns empty list" do
      assert Diff.render_diff("", @theme) == []
    end
  end
end
