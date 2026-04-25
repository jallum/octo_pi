defmodule OctoPi.Coder.ResourceLoaderTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Tool
  alias OctoPi.Coder.ResourceLoader

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "rl_test_#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    dir
  end

  defp write_file(dir, relative, content) do
    path = Path.join(dir, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
    path
  end

  defp tool(name), do: %Tool{name: name, description: "#{name} tool", parameters: %{}, handler: __MODULE__}

  # ── ResourceLoader.load/2 ──────────────────────────────────────

  describe "load/2 — empty filesystem" do
    test "returns empty struct when no dirs exist" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.context_files == []
      assert loader.system_prompt == nil
      assert loader.append_system_prompt == nil
      assert loader.skills == []
      assert loader.prompt_templates == []
    end
  end

  describe "load/2 — context files" do
    test "loads CLAUDE.md from cwd" do
      cwd = tmp_dir()
      write_file(cwd, "CLAUDE.md", "project instructions")
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert length(loader.context_files) == 1
      assert List.first(loader.context_files).content == "project instructions"
    end

    test "loads AGENTS.md preferentially over CLAUDE.md in same dir" do
      cwd = tmp_dir()
      write_file(cwd, "AGENTS.md", "agents file")
      write_file(cwd, "CLAUDE.md", "claude file")
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert length(loader.context_files) == 1
      assert List.first(loader.context_files).content == "agents file"
    end

    test "walks ancestors and collects context files" do
      parent = tmp_dir()
      cwd = Path.join(parent, "child")
      File.mkdir_p!(cwd)
      write_file(parent, "CLAUDE.md", "parent instructions")
      write_file(cwd, "CLAUDE.md", "child instructions")
      on_exit(fn -> File.rm_rf!(parent) end)

      loader = ResourceLoader.load(cwd, nil)

      paths = Enum.map(loader.context_files, & &1.content)
      assert "parent instructions" in paths
      assert "child instructions" in paths
    end

    test "loads from agent_dir when provided" do
      cwd = tmp_dir()
      agent_dir = tmp_dir()
      write_file(agent_dir, "CLAUDE.md", "global instructions")

      on_exit(fn ->
        File.rm_rf!(cwd)
        File.rm_rf!(agent_dir)
      end)

      loader = ResourceLoader.load(cwd, agent_dir)

      assert Enum.any?(loader.context_files, &(&1.content == "global instructions"))
    end
  end

  describe "load/2 — prompt files" do
    test "loads system_prompt from .pi/SYSTEM.md" do
      cwd = tmp_dir()
      write_file(cwd, ".pi/SYSTEM.md", "custom system prompt")
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.system_prompt == "custom system prompt"
    end

    test "system_prompt is nil when no SYSTEM.md" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.system_prompt == nil
    end

    test "loads append_system_prompt from .pi/APPEND_SYSTEM.md" do
      cwd = tmp_dir()
      write_file(cwd, ".pi/APPEND_SYSTEM.md", "extra instructions")
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.append_system_prompt == "extra instructions"
    end

    test "append_system_prompt is nil when no APPEND_SYSTEM.md" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.append_system_prompt == nil
    end
  end

  describe "load/2 — skills" do
    test "loads skills from .pi/skills" do
      cwd = tmp_dir()

      write_file(cwd, ".pi/skills/my-skill/SKILL.md", """
      ---
      description: My helpful skill
      ---
      Do the thing.
      """)

      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert length(loader.skills) == 1
      assert List.first(loader.skills).name == "my-skill"
    end

    test "returns empty skills when no skills dir" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.skills == []
    end
  end

  describe "load/2 — prompt templates" do
    test "loads templates from .pi/prompts" do
      cwd = tmp_dir()

      write_file(cwd, ".pi/prompts/greet.md", """
      ---
      description: Greet someone
      ---
      Hello $1!
      """)

      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert length(loader.prompt_templates) == 1
      assert List.first(loader.prompt_templates).name == "greet"
    end

    test "returns empty templates when no prompts dir" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert loader.prompt_templates == []
    end
  end

  describe "load/2 — all sources combined" do
    test "loads from all sources at once" do
      cwd = tmp_dir()
      write_file(cwd, "CLAUDE.md", "project context")
      write_file(cwd, ".pi/SYSTEM.md", "custom prompt")
      write_file(cwd, ".pi/APPEND_SYSTEM.md", "append text")
      write_file(cwd, ".pi/skills/do-thing/SKILL.md", "---\ndescription: Do a thing\n---\nDo it.")
      write_file(cwd, ".pi/prompts/cmd.md", "---\ndescription: Run command\n---\nRun $1")
      on_exit(fn -> File.rm_rf!(cwd) end)

      loader = ResourceLoader.load(cwd, nil)

      assert Enum.any?(loader.context_files, &String.contains?(&1.content, "project context"))
      assert loader.system_prompt == "custom prompt"
      assert loader.append_system_prompt == "append text"
      assert Enum.any?(loader.skills, &(&1.name == "do-thing"))
      assert Enum.any?(loader.prompt_templates, &(&1.name == "cmd"))
    end
  end

  # ── ResourceLoader.build_system_prompt/3 ──────────────────────

  describe "build_system_prompt/3" do
    test "renders with context_files injected" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read"), tool("bash")]

      loader = %ResourceLoader{
        context_files: [%{path: "/CLAUDE.md", content: "Be careful."}],
        system_prompt: nil,
        append_system_prompt: nil,
        skills: [],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "Be careful."
      assert prompt =~ "# Project Context"
    end

    test "renders with custom_prompt override from resource loader" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read")]

      loader = %ResourceLoader{
        context_files: [],
        system_prompt: "You are a fish.",
        append_system_prompt: nil,
        skills: [],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "You are a fish."
      refute prompt =~ "coding assistant"
    end

    test "renders with append_system_prompt" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read")]

      loader = %ResourceLoader{
        context_files: [],
        system_prompt: nil,
        append_system_prompt: "Extra instructions.",
        skills: [],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "Extra instructions."
    end

    test "renders skills section when read tool present" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read"), tool("bash")]

      loader = %ResourceLoader{
        context_files: [],
        system_prompt: nil,
        append_system_prompt: nil,
        skills: [
          %{
            name: "my-skill",
            description: "Does something",
            file_path: "/skills/my-skill/SKILL.md",
            base_dir: "/skills/my-skill",
            disable_model_invocation: false
          }
        ],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "<available_skills>"
      assert prompt =~ "my-skill"
    end

    test "empty loader renders default system prompt" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read"), tool("bash")]

      loader = %ResourceLoader{
        context_files: [],
        system_prompt: nil,
        append_system_prompt: nil,
        skills: [],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "coding assistant"
      assert prompt =~ "Current working directory:"
    end

    test "roundtrip: load then build produces valid system prompt" do
      cwd = tmp_dir()
      write_file(cwd, "CLAUDE.md", "Be helpful.")
      write_file(cwd, ".pi/APPEND_SYSTEM.md", "Always cite sources.")
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read"), tool("bash")]
      loader = ResourceLoader.load(cwd, nil)
      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "Be helpful."
      assert prompt =~ "Always cite sources."
      assert prompt =~ "Current working directory: #{cwd}"
    end
  end

  # ── SystemPrompt.render/1 integration (via build_system_prompt) ─

  describe "build_system_prompt/3 — correct render opts" do
    test "generates prompt compatible with SystemPrompt.render expectations" do
      cwd = tmp_dir()
      on_exit(fn -> File.rm_rf!(cwd) end)

      tools = [tool("read"), tool("bash"), tool("grep"), tool("find")]

      loader = %ResourceLoader{
        context_files: [],
        system_prompt: nil,
        append_system_prompt: nil,
        skills: [],
        prompt_templates: []
      }

      prompt = ResourceLoader.build_system_prompt(loader, cwd, tools)

      assert prompt =~ "- read:"
      assert prompt =~ "- bash:"
      assert prompt =~ "- grep:"
      assert prompt =~ "- find:"
    end
  end
end
