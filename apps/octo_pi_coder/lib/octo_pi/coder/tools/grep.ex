defmodule OctoPi.Coder.Tools.Grep do
  @moduledoc """
  `grep` built-in tool. Prefers ripgrep (`rg`) via `System.cmd/3`
  when it's on the PATH; falls back to a pure-Elixir scan
  otherwise. Honors `.gitignore` when rg is used.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.Tools.PathGuard

  @max_matches 200
  @rg_cache_key {__MODULE__, :rg_available?}

  @doc "Build a `%Tool{}` rooted at `cwd` — path defaults to cwd and must stay inside it."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "grep",
      label: "Grep",
      description: "Search file contents for a pattern.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string"},
          "path" => %{
            "type" => "string",
            "description" => "Directory or file (defaults to session cwd)."
          },
          "case_insensitive" => %{"type" => "boolean"}
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
    requested_path = Map.get(args, "path", cwd)
    case_insensitive? = Map.get(args, "case_insensitive", false)

    if AbortRef.aborted?(abort_ref) do
      {:ok, aborted_result()}
    else
      do_search(requested_path, cwd, pattern, case_insensitive?)
    end
  end

  defp aborted_result do
    %Result{
      is_error?: true,
      content: [%Content.Text{text: "grep aborted before execution"}]
    }
  end

  defp do_search(requested_path, cwd, pattern, case_insensitive?) do
    case PathGuard.resolve_or_error(requested_path, cwd) do
      {:error, %Result{} = r} ->
        {:ok, r}

      {:ok, path} ->
        matches = search(pattern, path, case_insensitive?)
        finalize(matches)
    end
  end

  defp search(pattern, path, case_insensitive?) do
    if rg_available?() do
      rg_search(pattern, path, case_insensitive?)
    else
      fallback_search(pattern, path, case_insensitive?)
    end
  end

  # Cache `rg` availability in `:persistent_term` — we call it once
  # per grep, and `System.find_executable/1` shells out under the
  # hood. Refresh by calling `refresh_rg_cache/0` (tests).
  defp rg_available? do
    case :persistent_term.get(@rg_cache_key, :unset) do
      :unset ->
        value = System.find_executable("rg") != nil
        :persistent_term.put(@rg_cache_key, value)
        value

      cached ->
        cached
    end
  end

  @doc false
  def refresh_rg_cache, do: :persistent_term.erase(@rg_cache_key)

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
