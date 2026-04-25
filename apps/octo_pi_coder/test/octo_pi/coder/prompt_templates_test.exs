defmodule OctoPi.Coder.PromptTemplatesTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.PromptTemplates

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "pt_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_template(dir, name, content) do
    File.write!(Path.join(dir, "#{name}.md"), content)
  end

  # ── substitute_args/2 ──────────────────────────────────────────

  describe "substitute_args/2" do
    test "$ARGUMENTS replaced with all args joined" do
      assert PromptTemplates.substitute_args("Test: $ARGUMENTS", ["a", "b", "c"]) == "Test: a b c"
    end

    test "$@ replaced with all args joined" do
      assert PromptTemplates.substitute_args("Test: $@", ["a", "b", "c"]) == "Test: a b c"
    end

    test "$@ and $ARGUMENTS produce same result" do
      args = ["foo", "bar", "baz"]
      assert PromptTemplates.substitute_args("$@", args) == PromptTemplates.substitute_args("$ARGUMENTS", args)
    end

    test "$1 replaced with first arg" do
      assert PromptTemplates.substitute_args("Hello $1!", ["world"]) == "Hello world!"
    end

    test "positional args $1 $2 replaced correctly" do
      assert PromptTemplates.substitute_args("$1 and $2", ["foo", "bar"]) == "foo and bar"
    end

    test "out-of-range positional arg becomes empty" do
      assert PromptTemplates.substitute_args("$1 $2 $3", ["a", "b"]) == "a b "
    end

    test "$0 becomes empty (1-indexed)" do
      assert PromptTemplates.substitute_args("$0", ["a", "b"]) == ""
    end

    test "argument values are NOT recursively substituted" do
      assert PromptTemplates.substitute_args("$ARGUMENTS", ["$1", "$ARGUMENTS"]) == "$1 $ARGUMENTS"
      assert PromptTemplates.substitute_args("$@", ["$100", "$1"]) == "$100 $1"
    end

    test "mixed $1 and $ARGUMENTS" do
      assert PromptTemplates.substitute_args("$1: $ARGUMENTS", ["prefix", "a", "b"]) ==
               "prefix: prefix a b"
    end

    test "empty args array — $ARGUMENTS becomes empty" do
      assert PromptTemplates.substitute_args("Test: $ARGUMENTS", []) == "Test: "
    end

    test "empty args array — $1 becomes empty" do
      assert PromptTemplates.substitute_args("Test: $1", []) == "Test: "
    end

    test "multiple $ARGUMENTS occurrences all replaced" do
      assert PromptTemplates.substitute_args("$ARGUMENTS and $ARGUMENTS", ["a", "b"]) == "a b and a b"
    end

    test "non-matching patterns preserved" do
      assert PromptTemplates.substitute_args("$A $$ $ $ARGS", ["a"]) == "$A $$ $ $ARGS"
    end

    test "case-sensitive — only $ARGUMENTS matched, not $arguments" do
      assert PromptTemplates.substitute_args("$arguments $Arguments $ARGUMENTS", ["a", "b"]) ==
               "$arguments $Arguments a b"
    end

    test "no placeholders — text unchanged" do
      assert PromptTemplates.substitute_args("Just plain text", ["a", "b"]) == "Just plain text"
    end

    test "inlined $1$2 joined without space" do
      assert PromptTemplates.substitute_args("$1$2", ["a", "b"]) == "ab"
    end

    test "$ARGUMENTS as part of word" do
      assert PromptTemplates.substitute_args("pre$ARGUMENTS", ["a", "b"]) == "prea b"
    end
  end

  describe "substitute_args/2 — array slicing" do
    test "${@:2} returns args from index 2 onward" do
      assert PromptTemplates.substitute_args("${@:2}", ["a", "b", "c", "d"]) == "b c d"
    end

    test "${@:1} returns all args" do
      assert PromptTemplates.substitute_args("${@:1}", ["a", "b", "c"]) == "a b c"
    end

    test "${@:2:2} returns 2 args starting at index 2" do
      assert PromptTemplates.substitute_args("${@:2:2}", ["a", "b", "c", "d"]) == "b c"
    end

    test "${@:0} treated as all args (bash convention)" do
      assert PromptTemplates.substitute_args("${@:0}", ["a", "b", "c"]) == "a b c"
    end

    test "out-of-range slice returns empty" do
      assert PromptTemplates.substitute_args("${@:99}", ["a", "b"]) == ""
    end

    test "length-0 slice returns empty" do
      assert PromptTemplates.substitute_args("${@:2:0}", ["a", "b", "c"]) == ""
    end

    test "length exceeding array returns available items" do
      assert PromptTemplates.substitute_args("${@:2:99}", ["a", "b", "c"]) == "b c"
    end

    test "slice processed before $@" do
      assert PromptTemplates.substitute_args("${@:2} vs $@", ["a", "b", "c"]) == "b c vs a b c"
    end

    test "slice args not recursively substituted" do
      assert PromptTemplates.substitute_args("${@:1}", ["${@:2}", "test"]) == "${@:2} test"
    end

    test "mixed positional, slice, and wildcard" do
      assert PromptTemplates.substitute_args("$1: ${@:2}", ["cmd", "arg1", "arg2"]) == "cmd: arg1 arg2"
    end

    test "multiple slices in template" do
      assert PromptTemplates.substitute_args("${@:1:1} and ${@:2}", ["a", "b", "c"]) == "a and b c"
    end

    test "slice with no surrounding space" do
      assert PromptTemplates.substitute_args("prefix${@:2}suffix", ["a", "b", "c"]) == "prefixb csuffix"
    end
  end

  # ── parse_args/1 ───────────────────────────────────────────────

  describe "parse_args/1" do
    test "parses space-separated args" do
      assert PromptTemplates.parse_args("a b c") == ["a", "b", "c"]
    end

    test "parses double-quoted arg with spaces" do
      assert PromptTemplates.parse_args(~s("first arg" second)) == ["first arg", "second"]
    end

    test "parses single-quoted arg with spaces" do
      assert PromptTemplates.parse_args("'first arg' second") == ["first arg", "second"]
    end

    test "empty string returns empty list" do
      assert PromptTemplates.parse_args("") == []
    end

    test "extra spaces are ignored" do
      assert PromptTemplates.parse_args("a  b   c") == ["a", "b", "c"]
    end

    test "tabs as separators" do
      assert PromptTemplates.parse_args("a\tb\tc") == ["a", "b", "c"]
    end

    test "empty quotes skipped" do
      assert PromptTemplates.parse_args(~s("" " ")) == [" "]
    end

    test "trailing spaces" do
      assert PromptTemplates.parse_args("a b c   ") == ["a", "b", "c"]
    end
  end

  # ── load_all/2 ─────────────────────────────────────────────────

  describe "load_all/2" do
    test "returns empty list when no template dirs exist" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptTemplates.load_all(cwd, nil) == []
    end

    test "loads template from project prompts dir" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)

      write_template(prompts_dir, "greet", """
      ---
      description: Greet someone
      ---
      Hello $1!
      """)

      on_exit(fn -> File.rm_rf!(cwd) end)

      templates = PromptTemplates.load_all(cwd, nil)
      assert length(templates) == 1
      assert List.first(templates).name == "greet"
      assert List.first(templates).description == "Greet someone"
    end

    test "name comes from filename without .md extension" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      write_template(prompts_dir, "my-template", "---\ndescription: Test\n---\nBody")
      on_exit(fn -> File.rm_rf!(cwd) end)

      [template] = PromptTemplates.load_all(cwd, nil)
      assert template.name == "my-template"
    end

    test "description falls back to first line truncated to 60 chars" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      write_template(prompts_dir, "nodesc", "This is the first line of the template content")
      on_exit(fn -> File.rm_rf!(cwd) end)

      [template] = PromptTemplates.load_all(cwd, nil)
      assert template.description == "This is the first line of the template content"
    end

    test "first-line description truncated at 60 chars with ellipsis" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      long = String.duplicate("x", 80)
      write_template(prompts_dir, "long", long)
      on_exit(fn -> File.rm_rf!(cwd) end)

      [template] = PromptTemplates.load_all(cwd, nil)
      assert String.length(template.description) == 63
      assert String.ends_with?(template.description, "...")
    end

    test "argument_hint loaded from frontmatter" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)

      write_template(prompts_dir, "pr", """
      ---
      description: Review PRs
      argument-hint: "<PR-URL>"
      ---
      Review: $@
      """)

      on_exit(fn -> File.rm_rf!(cwd) end)

      [template] = PromptTemplates.load_all(cwd, nil)
      assert template.argument_hint == "<PR-URL>"
    end

    test "argument_hint is nil when not present" do
      cwd = tmp_dir()
      prompts_dir = Path.join([cwd, ".pi", "prompts"])
      File.mkdir_p!(prompts_dir)
      write_template(prompts_dir, "nohint", "---\ndescription: No hint\n---\nBody")
      on_exit(fn -> File.rm_rf!(cwd) end)

      [template] = PromptTemplates.load_all(cwd, nil)
      assert template.argument_hint == nil
    end

    test "loads from global and project dirs" do
      cwd = tmp_dir()
      global_dir = tmp_dir()
      File.mkdir_p!(Path.join([cwd, ".pi", "prompts"]))
      File.mkdir_p!(Path.join(global_dir, "prompts"))
      write_template(Path.join([cwd, ".pi", "prompts"]), "local", "---\ndescription: Local\n---\nlocal")
      write_template(Path.join(global_dir, "prompts"), "global", "---\ndescription: Global\n---\nglobal")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(global_dir)
      end)

      templates = PromptTemplates.load_all(cwd, global_dir)
      names = MapSet.new(templates, & &1.name)
      assert MapSet.member?(names, "local")
      assert MapSet.member?(names, "global")
    end
  end

  # ── expand/2 ───────────────────────────────────────────────────

  describe "expand/2" do
    defp make_template(name, content, desc \\ "Desc") do
      %{name: name, content: content, description: desc, argument_hint: nil}
    end

    test "text not starting with / is returned unchanged" do
      templates = [make_template("greet", "Hello $1!")]
      assert PromptTemplates.expand("just text", templates) == "just text"
    end

    test "matching template expanded with args" do
      templates = [make_template("greet", "Hello $1!")]
      assert PromptTemplates.expand("/greet world", templates) == "Hello world!"
    end

    test "no matching template returns original text" do
      templates = [make_template("greet", "Hello $1!")]
      assert PromptTemplates.expand("/unknown arg", templates) == "/unknown arg"
    end

    test "template with no args" do
      templates = [make_template("hello", "Hello world")]
      assert PromptTemplates.expand("/hello", templates) == "Hello world"
    end

    test "template with quoted args" do
      templates = [make_template("fmt", "Format $1 with $2")]
      assert PromptTemplates.expand(~s(/fmt "first arg" second), templates) == "Format first arg with second"
    end

    test "$ARGUMENTS substituted in template" do
      templates = [make_template("cmd", "Run: $ARGUMENTS")]
      assert PromptTemplates.expand("/cmd a b c", templates) == "Run: a b c"
    end
  end
end
