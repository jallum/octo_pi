defmodule OctoPi.Coder.SystemPromptTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Tool
  alias OctoPi.Coder.SystemPrompt

  defp tool(name, description \\ nil) do
    %Tool{
      name: name,
      description: description,
      parameters: %{},
      handler: __MODULE__
    }
  end

  describe "render/1 — default prompt" do
    test "includes cwd and date" do
      prompt = SystemPrompt.render(cwd: "/tmp/project", tools: [])

      assert prompt =~ "Current working directory: /tmp/project"
      assert prompt =~ "Current date: #{Date.to_iso8601(Date.utc_today())}"
    end

    test "shows (none) for empty tools list" do
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [])
      assert prompt =~ "Available tools:\n(none)"
    end

    test "shows file paths guideline even with no tools" do
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [])
      assert prompt =~ "Show file paths clearly"
    end

    test "includes tools with descriptions" do
      tools = [
        tool("read", "Read file contents"),
        tool("bash", "Execute bash commands"),
        tool("edit", "Make surgical edits"),
        tool("write", "Create or overwrite files")
      ]

      prompt = SystemPrompt.render(cwd: "/tmp", tools: tools)

      assert prompt =~ "- read: Read file contents"
      assert prompt =~ "- bash: Execute bash commands"
      assert prompt =~ "- edit: Make surgical edits"
      assert prompt =~ "- write: Create or overwrite files"
    end

    test "omits tools with nil descriptions" do
      tools = [tool("read", "Read files"), tool("secret_tool")]
      prompt = SystemPrompt.render(cwd: "/tmp", tools: tools)

      assert prompt =~ "- read:"
      refute prompt =~ "secret_tool"
    end

    test "bash-only tools get bash file-operations guideline" do
      tools = [tool("bash", "Run commands")]
      prompt = SystemPrompt.render(cwd: "/tmp", tools: tools)

      assert prompt =~ "Use bash for file operations like ls, rg, find"
      refute prompt =~ "Prefer grep/find/ls"
    end

    test "bash + native search tools get prefer-native guideline" do
      tools = [
        tool("bash", "Run commands"),
        tool("grep", "Search files"),
        tool("find", "Find files")
      ]

      prompt = SystemPrompt.render(cwd: "/tmp", tools: tools)

      assert prompt =~ "Prefer grep/find/ls tools over bash"
      refute prompt =~ "Use bash for file operations"
    end
  end

  describe "render/1 — extra guidelines" do
    test "appends custom guidelines" do
      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [],
          guidelines: ["Use dynamic_tool for summaries."]
        )

      assert prompt =~ "- Use dynamic_tool for summaries."
    end

    test "deduplicates and trims guidelines" do
      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [],
          guidelines: [
            "Use dynamic_tool for summaries.",
            "  Use dynamic_tool for summaries.  ",
            "   "
          ]
        )

      matches =
        prompt
        |> String.split("\n")
        |> Enum.count(&(&1 == "- Use dynamic_tool for summaries."))

      assert matches == 1
    end
  end

  describe "render/1 — custom prompt" do
    test "replaces the default body" do
      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [],
          custom_prompt: "You are a fish."
        )

      assert prompt =~ "You are a fish."
      refute prompt =~ "coding assistant"
    end

    test "custom prompt still gets cwd and date" do
      prompt =
        SystemPrompt.render(
          cwd: "/home/x",
          tools: [],
          custom_prompt: "Custom."
        )

      assert prompt =~ "Current working directory: /home/x"
      assert prompt =~ "Current date:"
    end
  end

  describe "render/1 — append" do
    test "appends text after the body" do
      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [],
          append: "Extra instructions here."
        )

      assert prompt =~ "Extra instructions here."
    end
  end

  describe "render/1 — context files" do
    test "injects project context section" do
      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [],
          context_files: [
            %{path: "CLAUDE.md", content: "Be nice."},
            %{path: ".env.example", content: "KEY=val"}
          ]
        )

      assert prompt =~ "# Project Context"
      assert prompt =~ "## CLAUDE.md"
      assert prompt =~ "Be nice."
      assert prompt =~ "## .env.example"
      assert prompt =~ "KEY=val"
    end

    test "empty context files produce no section" do
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [], context_files: [])
      refute prompt =~ "Project Context"
    end
  end

  describe "render/1 — default_tools integration" do
    test "works with the real default_tools list" do
      tools = OctoPi.Coder.default_tools("/tmp/test")
      prompt = SystemPrompt.render(cwd: "/tmp/test", tools: tools)

      assert prompt =~ "- read:"
      assert prompt =~ "- bash:"
      assert prompt =~ "- edit:"
      assert prompt =~ "- write:"
      assert prompt =~ "- grep:"
      assert prompt =~ "- find:"
      assert prompt =~ "- ls:"
      assert prompt =~ "Prefer grep/find/ls tools over bash"
    end
  end

  describe "render/1 — skills section" do
    defp skill(name, desc, opts \\ []) do
      %{
        name: name,
        description: desc,
        file_path: "/skills/#{name}/SKILL.md",
        disable_model_invocation: Keyword.get(opts, :disable_model_invocation, false)
      }
    end

    test "no skills opt → no skills section" do
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")])
      refute prompt =~ "<available_skills>"
    end

    test "empty skills list → no skills section" do
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [])
      refute prompt =~ "<available_skills>"
    end

    test "single skill produces well-formed XML section" do
      s = skill("my-skill", "Does something useful")
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [s])
      assert prompt =~ "<available_skills>"
      assert prompt =~ "<skill>"
      assert prompt =~ "<name>my-skill</name>"
      assert prompt =~ "<description>Does something useful</description>"
      assert prompt =~ "<location>/skills/my-skill/SKILL.md</location>"
      assert prompt =~ "</skill>"
      assert prompt =~ "</available_skills>"
    end

    test "skills section intro text is present" do
      s = skill("my-skill", "Desc")
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [s])
      assert prompt =~ "The following skills provide specialized instructions"
      assert prompt =~ "Use the read tool to load a skill"
    end

    test "skill with disable_model_invocation: true is excluded" do
      hidden = skill("hidden", "Secret skill", disable_model_invocation: true)
      visible = skill("visible", "Visible skill")
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [hidden, visible])
      refute prompt =~ "hidden"
      assert prompt =~ "visible"
    end

    test "all skills excluded → no section" do
      hidden = skill("hidden", "Secret", disable_model_invocation: true)
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [hidden])
      refute prompt =~ "<available_skills>"
    end

    test "no read tool → skills section omitted" do
      s = skill("my-skill", "Desc")
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("bash")], skills: [s])
      refute prompt =~ "<available_skills>"
    end

    test "multiple skills all appear in section" do
      skills = [skill("a-skill", "First"), skill("b-skill", "Second")]
      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: skills)
      assert prompt =~ "<name>a-skill</name>"
      assert prompt =~ "<name>b-skill</name>"
    end

    test "XML entities escaped in name, description, and location" do
      s = %{
        name: "a&b",
        description: "Has <tags> and \"quotes\" and 'apostrophes'",
        file_path: "/path/with/>/file.md",
        disable_model_invocation: false
      }

      prompt = SystemPrompt.render(cwd: "/tmp", tools: [tool("read")], skills: [s])
      assert prompt =~ "<name>a&amp;b</name>"
      assert prompt =~ "Has &lt;tags&gt; and &quot;quotes&quot; and &apos;apostrophes&apos;"
      assert prompt =~ "&gt;/file.md"
    end

    test "skills section appears after context section and before date/cwd" do
      s = skill("my-skill", "Desc")

      prompt =
        SystemPrompt.render(
          cwd: "/tmp",
          tools: [tool("read")],
          skills: [s],
          context_files: [%{path: "/CLAUDE.md", content: "ctx"}]
        )

      skills_pos = prompt |> :binary.match("<available_skills>") |> elem(0)
      cwd_pos = prompt |> :binary.match("Current working directory") |> elem(0)
      ctx_pos = prompt |> :binary.match("# Project Context") |> elem(0)
      assert ctx_pos < skills_pos
      assert skills_pos < cwd_pos
    end
  end
end
