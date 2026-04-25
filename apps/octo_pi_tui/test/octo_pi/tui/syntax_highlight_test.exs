defmodule OctoPi.TUI.SyntaxHighlightTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.SyntaxHighlight
  alias OctoPi.TUI.Theme

  defp theme, do: Theme.load_builtin(:dark, :truecolor)

  describe "highlight/3" do
    test "highlights elixir code" do
      code = "defmodule Foo do\n  def bar, do: :ok\nend"
      result = SyntaxHighlight.highlight(code, "elixir", theme())
      assert is_list(result)
      assert length(result) == 3
      assert Enum.any?(result, &(&1 =~ "defmodule"))
    end

    test "highlights python code" do
      code = "def hello():\n  return 42"
      result = SyntaxHighlight.highlight(code, "python", theme())
      assert length(result) == 2
    end

    test "highlights javascript code" do
      code = "const x = 'hello';"
      result = SyntaxHighlight.highlight(code, "javascript", theme())
      assert length(result) == 1
    end

    test "falls back to plain for unknown language" do
      code = "some random code"
      result = SyntaxHighlight.highlight(code, "brainfuck", theme())
      assert result == ["some random code"]
    end

    test "falls back to plain for empty language" do
      code = "plain text"
      result = SyntaxHighlight.highlight(code, "", theme())
      assert result == ["plain text"]
    end

    test "applies ANSI color codes" do
      code = "def foo, do: :ok"
      result = SyntaxHighlight.highlight(code, "elixir", theme())
      line = hd(result)
      assert line =~ "\e["
    end

    test "handles empty code" do
      result = SyntaxHighlight.highlight("", "elixir", theme())
      assert result == [""]
    end

    test "handles multiline with blank lines" do
      code = "def foo\n\ndef bar"
      result = SyntaxHighlight.highlight(code, "elixir", theme())
      assert length(result) == 3
      assert Enum.at(result, 1) == ""
    end

    test "later patterns do not shred ANSI codes from earlier patterns" do
      code = "# comment"
      [line] = SyntaxHighlight.highlight(code, "bash", theme())
      stripped = String.replace(line, ~r/\e\[[0-9;]*m/, "")

      assert stripped == "# comment",
             "visible text should be unchanged but got: #{inspect(stripped)}"

      refute Regex.match?(~r/(?<!\e)\[\d/, line),
             "raw bracket-digit fragments should not appear: #{inspect(line)}"
    end

    test "number highlighting does not match inside existing ANSI sequences" do
      code = "x = 42"
      [line] = SyntaxHighlight.highlight(code, "elixir", theme())
      stripped = String.replace(line, ~r/\e\[[0-9;]*m/, "")
      assert stripped == "x = 42"

      # "42" should be wrapped exactly once, not have nested escapes
      parts = String.split(line, "42")
      assert length(parts) == 2, "42 should appear exactly once in output"
    end
  end

  describe "supported?/1" do
    test "returns true for known languages" do
      assert SyntaxHighlight.supported?("elixir")
      assert SyntaxHighlight.supported?("python")
      assert SyntaxHighlight.supported?("javascript")
      assert SyntaxHighlight.supported?("typescript")
      assert SyntaxHighlight.supported?("ruby")
      assert SyntaxHighlight.supported?("bash")
      assert SyntaxHighlight.supported?("sh")
    end

    test "returns false for unknown languages" do
      refute SyntaxHighlight.supported?("brainfuck")
      refute SyntaxHighlight.supported?("")
    end

    test "handles aliases" do
      assert SyntaxHighlight.supported?("js")
      assert SyntaxHighlight.supported?("ts")
      assert SyntaxHighlight.supported?("py")
      assert SyntaxHighlight.supported?("rb")
      assert SyntaxHighlight.supported?("shell")
    end
  end
end
