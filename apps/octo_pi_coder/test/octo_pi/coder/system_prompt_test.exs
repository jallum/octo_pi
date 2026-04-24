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
      assert prompt =~ "Current date: #{Date.utc_today() |> Date.to_iso8601()}"
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
end
