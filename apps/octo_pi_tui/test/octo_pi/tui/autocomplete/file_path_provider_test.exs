defmodule OctoPi.TUI.Autocomplete.FilePathProviderTest do
  # async: false — tests create temp directories via System.tmp_dir!
  use ExUnit.Case, async: false

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.FilePathProvider

  defp fixture_dir(entries) do
    base = Path.join(System.tmp_dir!(), "fpp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    for e <- entries, do: apply_entry(base, e)

    on_exit(fn -> File.rm_rf!(base) end)
    base
  end

  defp apply_entry(base, {:file, rel}) do
    path = Path.join(base, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  defp apply_entry(base, {:dir, rel}) do
    File.mkdir_p!(Path.join(base, rel))
  end

  defp labels(suggestions), do: Enum.map(suggestions, & &1.label)

  describe "trigger semantics" do
    test "returns empty for plain slash-command input" do
      base = fixture_dir([{:file, "a.txt"}])
      provider = FilePathProvider.new(cwd: base)
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "/help")
    end

    test "returns empty for non-triggering input" do
      base = fixture_dir([{:file, "a.txt"}])
      provider = FilePathProvider.new(cwd: base)
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "hello world")
    end

    test "triggers on @" do
      base = fixture_dir([{:file, "a.txt"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@")
      refute Enum.empty?(sugg)
    end
  end

  describe "@ empty query returns all entries (dirs first)" do
    test "directories ranked before files" do
      base =
        fixture_dir([
          {:file, "zz.txt"},
          {:dir, "aa"},
          {:file, "bb.txt"},
          {:dir, "cc"}
        ])

      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@")
      ls = labels(sugg)
      # directories (ending with /) appear before plain files
      first_file_idx = Enum.find_index(ls, &(not String.ends_with?(&1, "/")))
      last_dir_idx = Enum.find_index(ls, &String.ends_with?(&1, "/"))
      assert last_dir_idx < first_file_idx || first_file_idx == nil
    end

    test "includes hidden paths but excludes .git" do
      base =
        fixture_dir([
          {:file, ".env"},
          {:file, ".git/config"},
          {:file, "visible.txt"}
        ])

      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@")
      ls = labels(sugg)
      assert ".env" in ls
      assert "visible.txt" in ls
      refute Enum.any?(ls, &String.contains?(&1, ".git"))
    end
  end

  describe "@ fuzzy matching" do
    test "matches file by extension in query" do
      base = fixture_dir([{:file, "alpha.ex"}, {:file, "beta.md"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@.ex")
      assert Enum.any?(labels(sugg), &String.contains?(&1, "alpha.ex"))
    end

    test "case-insensitive match" do
      base = fixture_dir([{:file, "ReadMe.md"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@readme")
      assert labels(sugg) == ["ReadMe.md"]
    end

    test "returns nested paths" do
      base = fixture_dir([{:file, "packages/tui/src/autocomplete.ts"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@autocomplete")

      assert Enum.any?(
               labels(sugg),
               &String.contains?(&1, "packages/tui/src/autocomplete.ts")
             )
    end

    test "deeply nested path match" do
      base =
        fixture_dir([
          {:file, "a/b/c/d/e/deep_target_xy.ex"},
          {:file, "noise.ex"}
        ])

      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@deep_target")
      assert Enum.any?(labels(sugg), &String.contains?(&1, "deep_target_xy.ex"))
    end

    test "directory rank beats file rank at equal fuzzy score" do
      base =
        fixture_dir([
          {:file, "alpha"},
          {:dir, "alphaDir"}
        ])

      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@alpha")
      [first | _] = labels(sugg)
      assert String.ends_with?(first, "/")
    end
  end

  describe "quoting" do
    test "quotes paths containing spaces" do
      base = fixture_dir([{:file, "my docs/notes.md"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@notes")
      values = Enum.map(sugg, & &1.value)
      assert Enum.any?(values, &String.starts_with?(&1, "\""))
    end

    test "does not quote paths without spaces" do
      base = fixture_dir([{:file, "nospaces.md"}])
      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@nospaces")
      values = Enum.map(sugg, & &1.value)
      refute Enum.any?(values, &String.starts_with?(&1, "\""))
    end
  end

  describe "absolute path completion" do
    test "completes entries in a named absolute directory" do
      base = fixture_dir([{:file, "alpha.ex"}, {:file, "alphabet.ex"}])
      provider = FilePathProvider.new(cwd: base)

      {:ok, sugg} = Autocomplete.get_suggestions(provider, Path.join(base, "alpha"))
      ls = labels(sugg)
      assert Enum.any?(ls, &String.ends_with?(&1, "alpha.ex"))
      assert Enum.any?(ls, &String.ends_with?(&1, "alphabet.ex"))
    end
  end

  describe "symlinks" do
    @tag :symlink
    test "follows symlinked directories during @ walk" do
      base = fixture_dir([{:file, "real/a.ex"}, {:file, "real/b.ex"}])
      link_path = Path.join(base, "link")
      :ok = File.ln_s(Path.join(base, "real"), link_path)

      provider = FilePathProvider.new(cwd: base)
      {:ok, sugg} = Autocomplete.get_suggestions(provider, "@")
      ls = labels(sugg)
      assert Enum.any?(ls, &String.contains?(&1, "link"))
    end
  end
end
