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
    test "collapsed shows short result as preview" do
      te =
        ToolExecution.new("Read", "call-1", %{}, @theme)
        |> ToolExecution.set_result("short content", false)
        |> ToolExecution.set_expanded(false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "short content"))
    end

    test "collapsed shows last 5 lines for long output" do
      long_result = Enum.map_join(1..20, "\n", &"line #{&1}")

      te =
        ToolExecution.new("Bash", "call-1", %{}, @theme)
        |> ToolExecution.set_result(long_result, false)
        |> ToolExecution.set_expanded(false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "line 20"))
      assert Enum.any?(stripped, &(&1 =~ "line 16"))
      refute Enum.any?(stripped, &String.contains?(&1, "line 5"))
      assert Enum.any?(stripped, &(&1 =~ "15 earlier lines"))
    end

    test "expanded shows full result text" do
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

  # ── Custom tool renderers ─────────────────────────────────────

  describe "custom render_call" do
    test "delegates to render_call when pending" do
      render_call = fn ctx ->
        ["[custom-call] #{ctx.args[:file_path]}"]
      end

      te =
        ToolExecution.new("Read", "call-1", %{file_path: "/foo"}, @theme,
          render_call: render_call
        )

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[custom-call] /foo"))
    end

    test "is not invoked after result arrives" do
      render_call = fn _ctx -> ["[custom-call]"] end
      render_result = fn _ctx -> ["[custom-result]"] end

      te =
        ToolExecution.new("Read", "call-1", %{}, @theme,
          render_call: render_call,
          render_result: render_result
        )
        |> ToolExecution.set_result("done", false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      refute Enum.any?(stripped, &(&1 =~ "[custom-call]"))
      assert Enum.any?(stripped, &(&1 =~ "[custom-result]"))
    end
  end

  describe "custom render_result" do
    test "delegates to render_result on success" do
      render_result = fn ctx ->
        ["[custom-result] error=#{ctx.is_error}"]
      end

      te =
        ToolExecution.new("Bash", "call-1", %{}, @theme, render_result: render_result)
        |> ToolExecution.set_result("output", false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[custom-result] error=false"))
    end

    test "delegates to render_result on error" do
      render_result = fn ctx ->
        ["[error-render] #{Map.get(ctx.args, :command, "")}"]
      end

      te =
        ToolExecution.new("Bash", "call-1", %{command: "rm -rf"}, @theme,
          render_result: render_result
        )
        |> ToolExecution.set_result("denied", true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[error-render] rm -rf"))
    end

    test "receives context with expanded state" do
      render_result = fn ctx ->
        if ctx.expanded, do: ["[expanded-view]"], else: ["[collapsed-view]"]
      end

      te =
        ToolExecution.new("Read", "call-1", %{}, @theme, render_result: render_result)
        |> ToolExecution.set_result("data", false)

      collapsed = ToolExecution.render(te, 80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(collapsed, &(&1 =~ "[collapsed-view]"))

      expanded =
        te
        |> ToolExecution.set_expanded(true)
        |> ToolExecution.render(80)
        |> Enum.map(&strip_ansi/1)

      assert Enum.any?(expanded, &(&1 =~ "[expanded-view]"))
    end
  end

  describe "render_shell" do
    test ":self skips default box framing" do
      render_call = fn _ctx -> ["SELF-FRAMED-LINE"] end

      te =
        ToolExecution.new("Custom", "call-1", %{}, @theme,
          render_call: render_call,
          render_shell: :self
        )

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "SELF-FRAMED-LINE"))
      refute Enum.any?(stripped, &(&1 =~ "│"))
    end

    test ":default wraps custom content in standard box" do
      render_call = fn _ctx -> ["BOXED-LINE"] end

      te =
        ToolExecution.new("Custom", "call-1", %{}, @theme,
          render_call: render_call,
          render_shell: :default
        )

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "BOXED-LINE"))
      assert Enum.any?(stripped, &(&1 =~ "│"))
    end
  end

  describe "no custom renderers" do
    test "renders with default when no custom render functions set" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/bar"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "Read"))
      assert Enum.any?(stripped, &(&1 =~ "│"))
    end
  end
end
