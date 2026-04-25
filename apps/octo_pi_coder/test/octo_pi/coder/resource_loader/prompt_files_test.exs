defmodule OctoPi.Coder.ResourceLoader.PromptFilesTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.ResourceLoader.PromptFiles

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "prompt_files_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_file(dir, relative_path, content) do
    full_path = Path.join(dir, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, content)
    full_path
  end

  describe "load_system_prompt/2" do
    test "returns nil when no SYSTEM.md exists" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptFiles.load_system_prompt(cwd, nil) == nil
    end

    test "loads project-local .pi/SYSTEM.md" do
      cwd = tmp_dir()
      write_file(cwd, ".pi/SYSTEM.md", "project system prompt")
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptFiles.load_system_prompt(cwd, nil) == "project system prompt"
    end

    test "loads global SYSTEM.md when project absent" do
      cwd = tmp_dir()
      global_dir = tmp_dir()
      write_file(global_dir, "SYSTEM.md", "global system prompt")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(global_dir)
      end)

      assert PromptFiles.load_system_prompt(cwd, global_dir) == "global system prompt"
    end

    test "project SYSTEM.md takes priority over global" do
      cwd = tmp_dir()
      global_dir = tmp_dir()
      write_file(cwd, ".pi/SYSTEM.md", "project prompt")
      write_file(global_dir, "SYSTEM.md", "global prompt")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(global_dir)
      end)

      assert PromptFiles.load_system_prompt(cwd, global_dir) == "project prompt"
    end

    test "returns nil when agent_dir is nil and no project file" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptFiles.load_system_prompt(cwd, nil) == nil
    end
  end

  describe "load_append_system_prompt/2" do
    test "returns nil when no APPEND_SYSTEM.md exists" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptFiles.load_append_system_prompt(cwd, nil) == nil
    end

    test "loads project-local .pi/APPEND_SYSTEM.md" do
      cwd = tmp_dir()
      write_file(cwd, ".pi/APPEND_SYSTEM.md", "project append")
      on_exit(fn -> File.rm_rf!(cwd) end)
      assert PromptFiles.load_append_system_prompt(cwd, nil) == "project append"
    end

    test "loads global APPEND_SYSTEM.md when project absent" do
      cwd = tmp_dir()
      global_dir = tmp_dir()
      write_file(global_dir, "APPEND_SYSTEM.md", "global append")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(global_dir)
      end)

      assert PromptFiles.load_append_system_prompt(cwd, global_dir) == "global append"
    end

    test "project APPEND_SYSTEM.md takes priority over global" do
      cwd = tmp_dir()
      global_dir = tmp_dir()
      write_file(cwd, ".pi/APPEND_SYSTEM.md", "project append")
      write_file(global_dir, "APPEND_SYSTEM.md", "global append")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(global_dir)
      end)

      assert PromptFiles.load_append_system_prompt(cwd, global_dir) == "project append"
    end
  end
end
