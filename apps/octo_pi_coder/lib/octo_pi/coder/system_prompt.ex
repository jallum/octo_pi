defmodule OctoPi.Coder.SystemPrompt do
  @moduledoc """
  Builds the system prompt for the coding agent. Mirrors upstream
  pi-mono's `system-prompt.ts` — primes the model on available
  tools, working conventions, and file-handling etiquette so it
  uses tools proactively instead of narrating what it *could* do.
  """

  @doc """
  Render the system prompt.

  ## Options

    * `:cwd` — working directory (required)
    * `:tools` — list of `%OctoPi.Agent.Tool{}` structs; tools with
      non-empty descriptions appear in the "Available tools" section.
    * `:guidelines` — extra guideline bullets to append
    * `:custom_prompt` — replaces the default prompt body entirely
    * `:append` — text appended verbatim after the prompt body
    * `:context_files` — `[%{path: String.t(), content: String.t()}]`
      injected as a "Project Context" section

  """
  @spec render(keyword()) :: String.t()
  def render(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    tools = Keyword.get(opts, :tools, [])
    extra_guidelines = Keyword.get(opts, :guidelines, [])
    custom_prompt = Keyword.get(opts, :custom_prompt)
    append = Keyword.get(opts, :append)
    context_files = Keyword.get(opts, :context_files, [])
    skills = Keyword.get(opts, :skills, [])

    date = Date.to_iso8601(Date.utc_today())
    tool_names = Enum.map(tools, & &1.name)

    body = build_body(custom_prompt, tools, extra_guidelines)

    IO.iodata_to_binary([
      body,
      append_section(append),
      context_section(context_files),
      skills_section(skills, tool_names),
      "\nCurrent date: #{date}",
      "\nCurrent working directory: #{cwd}"
    ])
  end

  defp build_body(custom, _tools, _guidelines) when is_binary(custom), do: custom

  defp build_body(nil, tools, extra_guidelines) do
    tool_names = Enum.map(tools, & &1.name)
    tools_list = format_tools(tools)
    guidelines = build_guidelines(tool_names, extra_guidelines)

    """
    You are an expert coding assistant operating inside pi, a coding agent harness. \
    You help users by reading files, executing commands, editing code, and writing new files.

    Available tools:
    #{tools_list}

    In addition to the tools above, you may have access to other custom tools depending on the project.

    Guidelines:
    #{guidelines}\
    """
  end

  defp format_tools([]), do: "(none)"

  defp format_tools(tools) do
    tools
    |> Enum.filter(&(&1.description && &1.description != ""))
    |> Enum.map_join("\n", fn t -> "- #{t.name}: #{t.description}" end)
    |> case do
      "" -> "(none)"
      list -> list
    end
  end

  defp build_guidelines(tool_names, extra) do
    base =
      file_exploration_guideline(tool_names) ++
        Enum.map(extra, &String.trim/1) ++
        [
          "Be concise in your responses",
          "Show file paths clearly when working with files"
        ]

    base
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.map_join("\n", &"- #{&1}")
  end

  defp file_exploration_guideline(tool_names) do
    has_bash = "bash" in tool_names
    has_native = Enum.any?(tool_names, &(&1 in ~w(grep find ls)))

    cond do
      has_bash and has_native ->
        ["Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)"]

      has_bash ->
        ["Use bash for file operations like ls, rg, find"]

      true ->
        []
    end
  end

  defp append_section(nil), do: ""
  defp append_section(text), do: "\n\n#{text}"

  defp context_section([]), do: ""

  defp context_section(files) do
    body =
      Enum.map_join(files, "\n", fn %{path: path, content: content} ->
        "## #{path}\n\n#{content}\n"
      end)

    "\n\n# Project Context\n\nProject-specific instructions and guidelines:\n\n#{body}"
  end

  defp skills_section(skills, tool_names) do
    visible = Enum.reject(skills, & &1.disable_model_invocation)

    if visible == [] or "read" not in tool_names do
      ""
    else
      skill_entries = Enum.map_join(visible, "\n", &format_skill_entry/1)

      "\n\nThe following skills provide specialized instructions for specific tasks.\n" <>
        "Use the read tool to load a skill's file when the task matches its description.\n" <>
        "When a skill file references a relative path, resolve it against the skill directory " <>
        "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n" <>
        "<available_skills>\n" <>
        skill_entries <>
        "\n</available_skills>"
    end
  end

  defp format_skill_entry(skill) do
    "  <skill>\n" <>
      "    <name>#{xml_escape(skill.name)}</name>\n" <>
      "    <description>#{xml_escape(skill.description)}</description>\n" <>
      "    <location>#{xml_escape(skill.file_path)}</location>\n" <>
      "  </skill>"
  end

  defp xml_escape(str) do
    str
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end
end
