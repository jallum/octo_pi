defmodule OctoPi.Coder.Tools.Find do
  @moduledoc """
  `find` built-in tool. Glob-based file discovery via
  `Path.wildcard/2`. Respects the glob pattern's leading `**/` for
  recursive search.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @max_matches 500

  @doc "Build a `%Tool{}` registered under the agent."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "find",
      label: "Find",
      description: "Find files matching a glob pattern.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Glob pattern, e.g. '**/*.ex'"},
          "path" => %{"type" => "string", "description" => "Base directory (default: cwd)."}
        },
        "required" => ["pattern"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"pattern" => pattern} = args, _abort_ref, _on_update) do
    base = Map.get(args, "path", File.cwd!())
    full_pattern = Path.join(base, pattern)

    matches =
      full_pattern
      |> Path.wildcard(match_dot: true)
      |> Enum.take(@max_matches)

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
