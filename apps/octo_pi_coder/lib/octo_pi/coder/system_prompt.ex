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

    date = Date.utc_today() |> Date.to_iso8601()

    body = build_body(custom_prompt, tools, extra_guidelines)

    [
      body,
      append_section(append),
      context_section(context_files),
      "\nCurrent date: #{date}",
      "\nCurrent working directory: #{cwd}"
    ]
    |> IO.iodata_to_binary()
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
end
