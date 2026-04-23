defmodule OctoPi.Coder.Tools.Grep do
  @moduledoc """
  `grep` built-in tool. Prefers ripgrep (`rg`) via `System.cmd/3`
  when it's on the PATH; falls back to a pure-Elixir scan
  otherwise. Honors `.gitignore` when rg is used.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @max_matches 200

  @doc "Build a `%Tool{}` registered under the agent."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "grep",
      label: "Grep",
      description: "Search file contents for a pattern.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "path" => %{"type" => "string", "description" => "Directory or file."},
          "case_insensitive" => %{"type" => "boolean"}
        },
        "required" => ["pattern"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"pattern" => pattern} = args, _abort_ref, _on_update) do
    path = Map.get(args, "path", File.cwd!())
    case_insensitive? = Map.get(args, "case_insensitive", false)

    matches =
      case rg_available?() do
        true -> rg_search(pattern, path, case_insensitive?)
        false -> fallback_search(pattern, path, case_insensitive?)
      end

    finalize(matches)
  end

  defp rg_available?, do: System.find_executable("rg") != nil

  defp rg_search(pattern, path, case_insensitive?) do
    args = ["--no-heading", "--line-number", "--color", "never"]
    args = if case_insensitive?, do: ["-i" | args], else: args
    args = args ++ [pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {out, 0} -> String.split(out, "\n", trim: true) |> Enum.take(@max_matches)
      # rg exits 1 when no matches, 2+ on real error.
      {_, 1} -> []
      {err, _} -> {:error, err}
    end
  end

  defp fallback_search(pattern, path, case_insensitive?) do
    compile_opts = if case_insensitive?, do: [:caseless], else: []

    case Regex.compile(Regex.escape(pattern), compile_opts) do
      {:ok, regex} -> walk_and_match(path, regex)
      {:error, _} -> []
    end
  end

  defp walk_and_match(path, regex) do
    path
    |> all_files()
    |> Enum.flat_map(&match_file(&1, regex))
    |> Enum.take(@max_matches)
  end

  defp all_files(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> [path]
      {:ok, %File.Stat{type: :directory}} -> Path.wildcard(Path.join(path, "**/*"))
      _ -> []
    end
    |> Enum.filter(&regular?/1)
  end

  defp regular?(p) do
    case File.stat(p) do
      {:ok, %File.Stat{type: :regular}} -> true
      _ -> false
    end
  end

  defp match_file(path, regex) do
    case File.read(path) do
      {:ok, body} ->
        body
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _} -> Regex.match?(regex, line) end)
        |> Enum.map(fn {line, n} -> "#{path}:#{n}:#{line}" end)

      _ ->
        []
    end
  end

  defp finalize({:error, err}) do
    {:ok, %Result{is_error?: true, content: [%Content.Text{text: "grep failed: #{err}"}]}}
  end

  defp finalize([]) do
    {:ok, %Result{content: [%Content.Text{text: "(no matches)"}]}}
  end

  defp finalize(lines) do
    text = Enum.join(lines, "\n")
    {:ok, %Result{content: [%Content.Text{text: text}], details: %{count: length(lines)}}}
  end
end
