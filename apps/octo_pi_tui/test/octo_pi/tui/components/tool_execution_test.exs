defmodule OctoPi.TUI.Components.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  # ── Basic rendering ─────────────────────────────────────────────

  describe "render/2 pending state" do
    test "shows tool name" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/foo"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Read"))
    end

    test "shows arguments" do
      te = ToolExecution.new("Bash", "call-1", %{command: "ls -la"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "ls -la"))
    end

    test "uses pending background" do
      te = ToolExecution.new("Read", "call-1", %{}, @theme)
      lines = ToolExecution.render(te, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  # ── Result states ───────────────────────────────────────────────

  describe "set_result/3" do
    test "success shows result text when expanded" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("file contents here", false)
        |> ToolExecution.set_expanded(true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "file contents"))
    end

    test "success uses success background" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("ok", false)

      lines = ToolExecution.render(te, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "error shows error message" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("file not found", true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "file not found"))
    end
  end

  # ── Expand/collapse ─────────────────────────────────────────────

  describe "expand/collapse" do
    test "collapsed hides result text" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("hidden content", false)
        |> ToolExecution.set_expanded(false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      refute Enum.any?(stripped, &(&1 =~ "hidden content"))
    end

    test "expanded shows result text" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("visible content", false)
        |> ToolExecution.set_expanded(true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "visible content"))
    end

    test "toggle_expanded flips state" do
      te = ToolExecution.new("Read", "call-1", %{}, @theme)
      assert te.expanded == false
      te = ToolExecution.toggle_expanded(te)
      assert te.expanded == true
      te = ToolExecution.toggle_expanded(te)
      assert te.expanded == false
    end
  end

  # ── Streaming updates ──────────────────────────────────────────

  describe "update_partial/2" do
    test "updates partial result text" do
      te =
        ToolExecution.new("Bash", "call-1", %{command: "ls"}, @theme)
        |> ToolExecution.update_partial("partial output...")
        |> ToolExecution.set_expanded(true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "partial output"))
    end
  end

  # ── Tool name formatting ────────────────────────────────────────

  describe "header formatting" do
    test "shows tool name in header" do
      te = ToolExecution.new("Edit", "call-1", %{file: "test.ex"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Edit"))
    end
  end
end
