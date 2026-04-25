defmodule OctoPi.Coder.ResourceLoader.ContextFilesTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.ResourceLoader.ContextFiles

  # Build a temp directory tree and return the leaf path
  defp tmp_tree(structure) do
    root = Path.join(System.tmp_dir!(), "ctx_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(root)
    write_tree(root, structure)
    root
  end

  defp write_tree(base, items) do
    for {name, content_or_children} <- items do
      path = Path.join(base, name)

      case content_or_children do
        content when is_binary(content) ->
          File.mkdir_p!(Path.dirname(path))
          File.write!(path, content)

        children when is_list(children) ->
          File.mkdir_p!(path)
          write_tree(path, children)
      end
    end
  end

  describe "load_all/2" do
    test "returns empty list when no context files exist" do
      root = tmp_tree([])
      on_exit(fn -> File.rm_rf!(root) end)
      assert ContextFiles.load_all(root, nil) == []
    end

    test "loads CLAUDE.md from cwd" do
      root = tmp_tree([{"CLAUDE.md", "project instructions"}])
      on_exit(fn -> File.rm_rf!(root) end)

      result = ContextFiles.load_all(root, nil)
      assert length(result) == 1
      assert List.first(result).content == "project instructions"
    end

    test "loads AGENTS.md from cwd when present" do
      root = tmp_tree([{"AGENTS.md", "agent instructions"}])
      on_exit(fn -> File.rm_rf!(root) end)

      result = ContextFiles.load_all(root, nil)
      assert length(result) == 1
      assert List.first(result).content == "agent instructions"
    end

    test "AGENTS.md takes priority over CLAUDE.md in same directory" do
      root = tmp_tree([{"AGENTS.md", "agents content"}, {"CLAUDE.md", "claude content"}])
      on_exit(fn -> File.rm_rf!(root) end)

      result = ContextFiles.load_all(root, nil)
      assert length(result) == 1
      assert List.first(result).content == "agents content"
    end

    test "loads CLAUDE.md from ancestor directory when cwd has none" do
      root = tmp_tree([{"CLAUDE.md", "ancestor instructions"}, {"subdir", []}])
      cwd = Path.join(root, "subdir")
      on_exit(fn -> File.rm_rf!(root) end)

      result = ContextFiles.load_all(cwd, nil)
      assert length(result) == 1
      assert List.first(result).content == "ancestor instructions"
    end

    test "loads both cwd and ancestor context files, root-first" do
      root =
        tmp_tree([
          {"CLAUDE.md", "root instructions"},
          {"a", [{"CLAUDE.md", "a instructions"}, {"b", []}]}
        ])

      cwd = Path.join([root, "a", "b"])
      on_exit(fn -> File.rm_rf!(root) end)

      result = ContextFiles.load_all(cwd, nil)
      assert length(result) == 2
      assert Enum.at(result, 0).content == "root instructions"
      assert Enum.at(result, 1).content == "a instructions"
    end

    test "loads global context file before ancestor chain" do
      root = tmp_tree([{"CLAUDE.md", "project instructions"}])
      global_dir = tmp_tree([{"CLAUDE.md", "global instructions"}])

      on_exit(fn ->
        File.rm_rf!(root)
        File.rm_rf!(global_dir)
      end)

      result = ContextFiles.load_all(root, global_dir)
      assert length(result) == 2
      assert Enum.at(result, 0).content == "global instructions"
      assert Enum.at(result, 1).content == "project instructions"
    end

    test "deduplicates when global and cwd point to same file" do
      root = tmp_tree([{"CLAUDE.md", "shared instructions"}])
      on_exit(fn -> File.rm_rf!(root) end)

      # Pass the same directory as both cwd and agentDir
      result = ContextFiles.load_all(root, root)
      assert length(result) == 1
    end

    test "path field is the absolute file path" do
      root = tmp_tree([{"CLAUDE.md", "instructions"}])
      on_exit(fn -> File.rm_rf!(root) end)

      [%{path: path}] = ContextFiles.load_all(root, nil)
      assert Path.absname(path) == path
      assert String.ends_with?(path, "CLAUDE.md")
    end
  end
end
