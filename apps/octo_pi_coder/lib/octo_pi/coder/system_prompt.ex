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
    * `:date` — `%Date{}` to embed (default: `Date.utc_today()`)

  """
  @type render_opts :: [
          cwd: String.t(),
          tools: [OctoPi.Agent.Tool.t()],
          guidelines: [String.t()],
          custom_prompt: String.t() | nil,
          append: String.t() | nil,
          context_files: [%{path: String.t(), content: String.t()}],
          skills: [map()],
          date: Date.t()
        ]

  @spec render(render_opts()) :: String.t()
  def render(opts) do
    cwd = Keyword.fetch!(opts, :cwd)
    tools = Keyword.get(opts, :tools, [])
    tool_names = Enum.map(tools, & &1.name)

    opts
    |> Keyword.get(:custom_prompt)
    |> build_body(tools, tool_names, Keyword.get(opts, :guidelines, []))
    |> append_section(Keyword.get(opts, :append))
    |> context_section(Keyword.get(opts, :context_files, []))
    |> skills_section(Keyword.get(opts, :skills, []), tool_names)
    |> date_section(Keyword.get(opts, :date, Date.utc_today()))
    |> cwd_section(cwd)
  end

  defp build_body(nil, tools, tool_names, extra_guidelines) do
    """
    You are an expert coding assistant operating inside pi, a coding agent harness. \
    You help users by reading files, executing commands, editing code, and writing new files.

    Available tools:
    #{format_tool_summary(tools)}

    In addition to the tools above, you may have access to other custom tools depending on the project.

    Guidelines:
    #{format_guidelines(tool_names, extra_guidelines)}\
    """
  end

  defp build_body(custom, _tools, _tool_names, _guidelines) when is_binary(custom), do: custom

  defp format_tool_summary(tools) do
    tools
    |> Enum.filter(&(&1.description && &1.description != ""))
    |> case do
      [] -> "(none)"
      filtered -> Enum.map_join(filtered, "\n", fn t -> "- #{t.name}: #{t.prompt_snippet || t.description}" end)
    end
  end

  defp format_guidelines(tool_names, extra) do
    [
      file_exploration_guideline(tool_names),
      format_guideline_extras(extra),
      "Be concise in your responses",
      "Show file paths clearly when working with files"
    ]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join("\n", &"- #{&1}")
  end

  defp format_guideline_extras(extra) when is_list(extra) do
    extra
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp format_guideline_extras(_), do: nil

  defp file_exploration_guideline(tool_names) do
    has_bash = "bash" in tool_names
    has_native = Enum.any?(tool_names, &(&1 in ~w(grep find ls)))

    cond do
      has_bash and has_native ->
        "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)"

      has_bash ->
        "Use bash for file operations like ls, rg, find"

      true ->
        nil
    end
  end

  defp append_section(body, nil), do: body
  defp append_section(body, text), do: body <> "\n\n#{text}"

  defp context_section(body, []), do: body

  defp context_section(body, files) do
    body <>
      """


      # Project Context

      Project-specific instructions and guidelines:

      #{Enum.map_join(files, "\n", fn %{path: p, content: c} -> "## #{p}\n\n#{c}\n" end)}\
      """
  end

  defp skills_section(body, skills, tool_names) do
    if "read" in tool_names do
      body <> (skills |> Enum.reject(& &1.disable_model_invocation) |> format_skills_section())
    else
      body
    end
  end

  defp format_skills_section([]), do: <<>>

  defp format_skills_section(skills) do
    """


    The following skills provide specialized instructions for specific tasks.
    Use the read tool to load a skill's file when the task matches its description.
    When a skill file references a relative path, resolve it against the skill directory \
    (parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.

    <available_skills>
    #{Enum.map_join(skills, "\n", &format_skill_entry/1)}
    </available_skills>\
    """
  end

  defp date_section(body, date), do: body <> "\nCurrent date: #{Date.to_iso8601(date)}"
  defp cwd_section(body, cwd), do: body <> "\nCurrent working directory: #{cwd}"

  defp format_skill_entry(%{name: name, description: desc, file_path: path}) do
    """
      <skill>
        <name>#{xml_escape(name)}</name>
        <description>#{xml_escape(desc)}</description>
        <location>#{xml_escape(path)}</location>
      </skill>\
    """
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
