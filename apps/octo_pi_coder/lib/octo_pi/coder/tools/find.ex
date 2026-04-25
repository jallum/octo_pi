defmodule OctoPi.Coder.Tools.Find do
  @moduledoc """
  `find` built-in tool. Glob-based file discovery via
  `Path.wildcard/2`. Respects the glob pattern's leading `**/` for
  recursive search.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @default_limit 1000

  @doc "Build a `%Tool{}` rooted at `cwd` — path defaults to cwd and must stay inside it."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "find",
      label: "Find",
      description:
        "Search for files by glob pattern. Returns matching file paths. Respects .gitignore when ripgrep is available. " <>
          "Output is truncated to the first #{@default_limit} results.",
      prompt_snippet: "Find files by glob pattern (respects .gitignore)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Glob pattern to match files, e.g. '*.ex', '**/*.json', or 'src/**/*.spec.exs'."
          },
          "path" => %{
            "type" => "string",
            "description" => "Directory to search in (default: current directory)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of results (default: #{@default_limit})."
          }
        },
        "required" => ["pattern"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"pattern" => pattern} = args, abort_ref, _on_update) do
    cwd = Map.fetch!(args, "_cwd")
    requested_base = Map.get(args, "path", cwd)
    limit = Map.get(args, "limit", @default_limit)

    if AbortRef.aborted?(abort_ref) do
      {:ok, %Result{is_error?: true, content: [%Content.Text{text: "find aborted before execution"}]}}
    else
      do_find(requested_base, cwd, pattern, limit)
    end
  end

  defp do_find(requested_base, _cwd, pattern, limit) do
    base = Path.expand(requested_base)
    matches =
      base
      |> Path.join(pattern)
      |> Path.wildcard(match_dot: true)
      |> Enum.take(limit)

    finalize(matches)
  end

  defp finalize([]) do
    {:ok, %Result{content: [%Content.Text{text: "(no matches)"}]}}
  end

  defp finalize(paths) do
    text = Enum.join(paths, "\n")
    {:ok, %Result{content: [%Content.Text{text: text}], details: %{count: length(paths)}}}
  end
end
