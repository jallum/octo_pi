defmodule OctoPi.TUI.Components.ToolExecutionTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp header_text(te) do
    te
    |> ToolExecution.render(80)
    |> Enum.map(&strip_ansi/1)
    |> Enum.find(&(String.trim(&1) != ""))
  end

  # count non-empty background-colored lines in rendered output
  defp bg_line_count(te) do
    te
    |> ToolExecution.render(80)
    |> Enum.count(fn line -> line =~ "\e[48;" end)
  end

  # ── Basic rendering ─────────────────────────────────────────────

  describe "render/2 pending state" do
    test "shows tool name" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/foo"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "read"))
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

    test "no extra blank line inside box when no result" do
      te = ToolExecution.new("Bash", "call-1", %{command: "ls"}, @theme)
      # padding_y=1 gives top + bottom padding = 2 bg lines, plus 1 content line = 3 total
      assert bg_line_count(te) == 3
    end
  end

  # ── Result states ───────────────────────────────────────────────

  describe "set_result/3" do
    test "success shows result text when expanded" do
      te =
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme)
        |> ToolExecution.set_result("file contents here", false)
        |> ToolExecution.set_expanded(true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "file contents"))
    end

    test "success uses success background" do
      te =
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme)
        |> ToolExecution.set_result("ok", false)

      lines = ToolExecution.render(te, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "error shows error message" do
      te =
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme)
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
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme)
        |> ToolExecution.set_result("short content", false)
        |> ToolExecution.set_expanded(false)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "short content"))
    end

    test "collapsed shows last 5 lines for long output" do
      long_result = Enum.map_join(1..20, "\n", &"line #{&1}")

      te =
        "Bash"
        |> ToolExecution.new("call-1", %{}, @theme)
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
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme)
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
        "Bash"
        |> ToolExecution.new("call-1", %{command: "ls"}, @theme)
        |> ToolExecution.update_partial("partial output...")
        |> ToolExecution.set_expanded(true)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "partial output"))
    end
  end

  # ── Per-tool header formatting (upstream parity) ─────────────────

  describe "Bash header" do
    test "shows $ command" do
      te = ToolExecution.new("Bash", "call-1", %{command: "ls -la"}, @theme)
      header = header_text(te)
      assert header =~ "$ ls -la"
    end

    test "truncates long commands" do
      long_cmd = String.duplicate("x", 200)
      te = ToolExecution.new("Bash", "call-1", %{command: long_cmd}, @theme)
      header = header_text(te)
      assert header =~ "$ "
      assert String.length(header) < 200
    end

    test "shows timeout suffix" do
      te = ToolExecution.new("Bash", "call-1", %{command: "sleep 60", timeout: 120}, @theme)
      header = header_text(te)
      assert header =~ "$ sleep 60"
      assert header =~ "timeout 120s"
    end
  end

  describe "Read header" do
    test "shows read path" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/foo/bar.ex"}, @theme)
      header = header_text(te)
      assert header =~ "read"
      assert header =~ "/foo/bar.ex"
    end

    test "shows line range with offset and limit" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/foo.ex", offset: 10, limit: 20}, @theme)
      header = header_text(te)
      assert header =~ "/foo.ex"
      assert header =~ ":10-29"
    end

    test "shows offset only without limit" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/foo.ex", offset: 5}, @theme)
      header = header_text(te)
      assert header =~ ":5"
    end
  end

  describe "Edit header" do
    test "shows edit path" do
      te = ToolExecution.new("Edit", "call-1", %{file_path: "/src/app.ex"}, @theme)
      header = header_text(te)
      assert header =~ "edit"
      assert header =~ "/src/app.ex"
    end
  end

  describe "Write header" do
    test "shows write path" do
      te = ToolExecution.new("Write", "call-1", %{file_path: "/src/new.ex", content: "hello"}, @theme)
      header = header_text(te)
      assert header =~ "write"
      assert header =~ "/src/new.ex"
    end
  end

  describe "Grep header" do
    test "shows grep pattern in path" do
      te = ToolExecution.new("Grep", "call-1", %{pattern: "defmodule", path: "/src"}, @theme)
      header = header_text(te)
      assert header =~ "grep"
      assert header =~ "/defmodule/"
      assert header =~ "in /src"
    end

    test "shows glob when present" do
      te = ToolExecution.new("Grep", "call-1", %{pattern: "TODO", path: ".", glob: "*.ex"}, @theme)
      header = header_text(te)
      assert header =~ "*.ex"
    end

    test "shows limit when present" do
      te = ToolExecution.new("Grep", "call-1", %{pattern: "TODO", path: ".", limit: 10}, @theme)
      header = header_text(te)
      assert header =~ "limit 10"
    end
  end

  describe "Find header" do
    test "shows find pattern in path" do
      te = ToolExecution.new("Find", "call-1", %{pattern: "*.ex", path: "/src"}, @theme)
      header = header_text(te)
      assert header =~ "find"
      assert header =~ "*.ex"
      assert header =~ "in /src"
    end

    test "shows limit when present" do
      te = ToolExecution.new("Find", "call-1", %{pattern: "*.ex", path: "/src", limit: 5}, @theme)
      header = header_text(te)
      assert header =~ "limit 5"
    end
  end

  describe "LS header" do
    test "shows ls path" do
      te = ToolExecution.new("ls", "call-1", %{path: "/src"}, @theme)
      header = header_text(te)
      assert header =~ "ls"
      assert header =~ "/src"
    end

    test "shows limit when present" do
      te = ToolExecution.new("ls", "call-1", %{path: "/src", limit: 50}, @theme)
      header = header_text(te)
      assert header =~ "limit 50"
    end
  end

  describe "string-keyed args (JSON decode path)" do
    test "Bash with string keys" do
      te = ToolExecution.new("Bash", "call-1", %{"command" => "echo hi"}, @theme)
      header = header_text(te)
      assert header =~ "$ echo hi"
    end

    test "Read with string keys" do
      te = ToolExecution.new("Read", "call-1", %{"file_path" => "/src/app.ex", "offset" => 5}, @theme)
      header = header_text(te)
      assert header =~ "/src/app.ex"
      assert header =~ ":5"
    end
  end

  describe "unknown tool header" do
    test "falls back to generic key=value format" do
      te = ToolExecution.new("CustomTool", "call-1", %{foo: "bar", baz: 42}, @theme)
      header = header_text(te)
      assert header =~ "CustomTool"
    end
  end

  describe "status prefix in header" do
    test "pending shows spinner" do
      te = ToolExecution.new("Bash", "call-1", %{command: "ls"}, @theme)
      header = header_text(te)
      assert header =~ "⏳"
    end

    test "success shows checkmark" do
      te =
        "Bash"
        |> ToolExecution.new("call-1", %{command: "ls"}, @theme)
        |> ToolExecution.set_result("ok", false)

      header = header_text(te)
      assert header =~ "✓"
    end

    test "error shows x" do
      te =
        "Bash"
        |> ToolExecution.new("call-1", %{command: "ls"}, @theme)
        |> ToolExecution.set_result("fail", true)

      header = header_text(te)
      assert header =~ "✗"
    end
  end

  # ── Custom tool renderers ─────────────────────────────────────

  describe "custom render_call" do
    test "delegates to render_call when pending" do
      render_call = fn ctx ->
        ["[custom-call] #{ctx.args[:file_path]}"]
      end

      te =
        ToolExecution.new("Read", "call-1", %{file_path: "/foo"}, @theme, render_call: render_call)

      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "[custom-call] /foo"))
    end

    test "is not invoked after result arrives" do
      render_call = fn _ctx -> ["[custom-call]"] end
      render_result = fn _ctx -> ["[custom-result]"] end

      te =
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme,
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
        "Bash"
        |> ToolExecution.new("call-1", %{}, @theme, render_result: render_result)
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
        "Bash"
        |> ToolExecution.new("call-1", %{command: "rm -rf"}, @theme, render_result: render_result)
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
        "Read"
        |> ToolExecution.new("call-1", %{}, @theme, render_result: render_result)
        |> ToolExecution.set_result("data", false)

      collapsed = te |> ToolExecution.render(80) |> Enum.map(&strip_ansi/1)
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
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  describe "no custom renderers" do
    test "renders with default when no custom render functions set" do
      te = ToolExecution.new("Read", "call-1", %{file_path: "/bar"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "read"))
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end
  end

  describe "borderless rendering (upstream parity)" do
    test "tool box uses background color, not border characters" do
      te = ToolExecution.new("Read", "call-1", %{}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)

      refute Enum.any?(stripped, &(&1 =~ "┌")),
             "should not have top border"

      refute Enum.any?(stripped, &(&1 =~ "└")),
             "should not have bottom border"

      refute Enum.any?(stripped, &(String.starts_with?(&1, "│") or String.ends_with?(&1, "│"))),
             "should not have side borders"

      assert Enum.any?(lines, &(&1 =~ "\e[48;")),
             "should have background color"
    end

    test "header text is inside the box as content, not in a border title" do
      te = ToolExecution.new("Bash", "call-1", %{command: "ls"}, @theme)
      lines = ToolExecution.render(te, 80)
      stripped = Enum.map(lines, &strip_ansi/1)

      header_line = Enum.find(stripped, &(&1 =~ "$ ls"))
      refute header_line =~ "┌", "header should not be in a border"
      refute header_line =~ "─", "header should not be in a border"
    end

    test "box content is padded with spaces to full width" do
      te = ToolExecution.new("Read", "call-1", %{}, @theme)
      lines = ToolExecution.render(te, 40)

      content_lines = Enum.filter(lines, &(&1 =~ "\e[48;"))

      for line <- content_lines do
        assert WrapAnsi.visible_width(strip_ansi(line)) >= 40,
               "line should be padded to full width: #{inspect(strip_ansi(line))}"
      end
    end
  end
end
