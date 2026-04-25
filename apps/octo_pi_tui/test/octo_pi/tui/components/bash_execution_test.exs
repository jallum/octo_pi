defmodule OctoPi.TUI.Components.BashExecutionTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.BashExecution
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)
  @preview_lines 20

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp render_stripped(be, width \\ 80) do
    be |> BashExecution.render(width) |> Enum.map(&strip_ansi/1)
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/3" do
    test "creates a running bash execution" do
      be = BashExecution.new("ls -la", @theme)
      assert be.command == "ls -la"
      assert be.status == :running
      assert be.output_lines == []
      assert be.exit_code == nil
      assert be.expanded == false
    end

    test "excluded_from_context flag" do
      be = BashExecution.new("echo hi", @theme, excluded: true)
      assert be.excluded == true
    end
  end

  # ── Streaming output ───────────────────────────────────────────

  describe "append_output/2" do
    test "accumulates output lines" do
      be =
        BashExecution.new("ls", @theme)
        |> BashExecution.append_output("file1\nfile2\n")

      assert be.output_lines == ["file1", "file2", ""]
    end

    test "continues incomplete lines across chunks" do
      be =
        BashExecution.new("cat", @theme)
        |> BashExecution.append_output("hel")
        |> BashExecution.append_output("lo\nworld")

      assert be.output_lines == ["hello", "world"]
    end

    test "normalizes \\r\\n to \\n" do
      be =
        BashExecution.new("cmd", @theme)
        |> BashExecution.append_output("line1\r\nline2\r\n")

      assert be.output_lines == ["line1", "line2", ""]
    end
  end

  # ── Completion ─────────────────────────────────────────────────

  describe "set_complete/3" do
    test "exit code 0 sets status to :complete" do
      be =
        BashExecution.new("ls", @theme)
        |> BashExecution.set_complete(0)

      assert be.status == :complete
      assert be.exit_code == 0
    end

    test "non-zero exit code sets status to :error" do
      be =
        BashExecution.new("false", @theme)
        |> BashExecution.set_complete(1)

      assert be.status == :error
      assert be.exit_code == 1
    end

    test "cancelled flag sets status to :cancelled" do
      be =
        BashExecution.new("sleep", @theme)
        |> BashExecution.set_complete(nil, cancelled: true)

      assert be.status == :cancelled
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2 — command header" do
    test "shows $ prefix with command" do
      be = BashExecution.new("echo hello", @theme)
      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "$ echo hello"))
    end
  end

  describe "render/2 — running state" do
    test "shows running indicator" do
      be = BashExecution.new("sleep 10", @theme)
      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "Running"))
    end
  end

  describe "render/2 — output display" do
    test "shows streaming output when expanded" do
      be =
        BashExecution.new("ls", @theme)
        |> BashExecution.append_output("file1\nfile2")
        |> BashExecution.set_expanded(true)

      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "file1"))
      assert Enum.any?(lines, &(&1 =~ "file2"))
    end

    test "collapsed shows last #{@preview_lines} lines" do
      output = Enum.map_join(1..30, "\n", &"line-#{&1}")

      be =
        BashExecution.new("cmd", @theme)
        |> BashExecution.append_output(output)
        |> BashExecution.set_complete(0)

      lines = render_stripped(be)
      refute Enum.any?(lines, &(&1 =~ "line-1\b"))
      assert Enum.any?(lines, &(&1 =~ "line-30"))
    end

    test "collapsed shows hidden line count" do
      output = Enum.map_join(1..30, "\n", &"line-#{&1}")

      be =
        BashExecution.new("cmd", @theme)
        |> BashExecution.append_output(output)
        |> BashExecution.set_complete(0)

      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "10 more lines"))
    end
  end

  describe "render/2 — exit code display" do
    test "error exit code is shown" do
      be =
        BashExecution.new("false", @theme)
        |> BashExecution.set_complete(127)

      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "exit 127"))
    end

    test "cancelled status is shown" do
      be =
        BashExecution.new("sleep", @theme)
        |> BashExecution.set_complete(nil, cancelled: true)

      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "cancelled"))
    end
  end

  # ── Expand/collapse ────────────────────────────────────────────

  describe "expand/collapse" do
    test "expanded shows all output lines" do
      output = Enum.map_join(1..30, "\n", &"line-#{&1}")

      be =
        BashExecution.new("cmd", @theme)
        |> BashExecution.append_output(output)
        |> BashExecution.set_complete(0)
        |> BashExecution.set_expanded(true)

      lines = render_stripped(be)
      assert Enum.any?(lines, &(&1 =~ "line-1"))
      assert Enum.any?(lines, &(&1 =~ "line-30"))
    end

    test "toggle_expanded flips state" do
      be = BashExecution.new("ls", @theme)
      assert be.expanded == false
      be = BashExecution.toggle_expanded(be)
      assert be.expanded == true
      be = BashExecution.toggle_expanded(be)
      assert be.expanded == false
    end
  end

  # ── Output accessor ────────────────────────────────────────────

  describe "borderless rendering (upstream parity)" do
    test "bash box uses background color, not border characters" do
      be = BashExecution.new("ls", @theme)
      lines = BashExecution.render(be, 80)
      stripped = Enum.map(lines, &strip_ansi/1)

      refute Enum.any?(stripped, &(&1 =~ "┌")), "should not have top border"
      refute Enum.any?(stripped, &(&1 =~ "└")), "should not have bottom border"
    end

    test "header is inside the box as content" do
      be = BashExecution.new("echo hi", @theme)
      lines = BashExecution.render(be, 80)
      stripped = Enum.map(lines, &strip_ansi/1)

      header_line = Enum.find(stripped, &(&1 =~ "$ echo hi"))
      refute header_line =~ "─", "header should not be in a border"
    end
  end

  describe "get_output/1" do
    test "returns joined output" do
      be =
        BashExecution.new("cmd", @theme)
        |> BashExecution.append_output("a\nb\nc")

      assert BashExecution.get_output(be) == "a\nb\nc"
    end
  end
end
