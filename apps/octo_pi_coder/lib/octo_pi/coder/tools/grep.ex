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

  @default_limit 100
  @max_context_lines 10
  @rg_cache_key {__MODULE__, :rg_available?}

  @doc "Build a `%Tool{}` rooted at `cwd` — path defaults to cwd and must stay inside it."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "grep",
      label: "Grep",
      description:
        "Search file contents for a pattern (regex by default). Honors .gitignore when ripgrep is available. " <>
          "Returns matching lines with file path and line number. " <>
          "Output is truncated to the first #{@default_limit} matches.",
      prompt_snippet: "Search file contents by pattern (respects .gitignore)",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{"type" => "string", "description" => "Search pattern (regex or literal string)."},
          "path" => %{
            "type" => "string",
            "description" => "Directory or file to search (default: current directory)."
          },
          "glob" => %{
            "type" => "string",
            "description" => "Filter files by glob pattern, e.g. '*.ex' or '**/*.spec.exs'."
          },
          "ignoreCase" => %{"type" => "boolean", "description" => "Case-insensitive search (default: false)."},
          "literal" => %{
            "type" => "boolean",
            "description" => "Treat pattern as literal string instead of regex (default: false)."
          },
          "context" => %{
            "type" => "integer",
            "description" => "Number of lines to show before and after each match (default: 0)."
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of matches to return (default: #{@default_limit})."
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
    requested_path = Map.get(args, "path", cwd)
    ignore_case? = Map.get(args, "ignoreCase", false)
    literal? = Map.get(args, "literal", false)
    glob = Map.get(args, "glob")
    context = args |> Map.get("context", 0) |> min(@max_context_lines)
    limit = Map.get(args, "limit", @default_limit)

    if AbortRef.aborted?(abort_ref) do
      {:ok, aborted_result()}
    else
      do_search(requested_path, cwd, pattern, ignore_case?, literal?, glob, context, limit)
    end
  end

  defp aborted_result do
    %Result{
      is_error?: true,
      content: [%Content.Text{text: "grep aborted before execution"}]
    }
  end

  defp do_search(requested_path, cwd, pattern, ignore_case?, literal?, glob, context, limit) do
    case PathGuard.resolve_or_error(requested_path, cwd) do
      {:error, %Result{} = r} ->
        {:ok, r}

      {:ok, path} ->
        matches = search(pattern, path, ignore_case?, literal?, glob, context, limit)
        finalize(matches)
    end
  end

  defp search(pattern, path, ignore_case?, literal?, glob, context, limit) do
    if rg_available?() do
      rg_search(pattern, path, ignore_case?, literal?, glob, context, limit)
    else
      fallback_search(pattern, path, ignore_case?, limit)
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

  defp rg_search(pattern, path, ignore_case?, literal?, glob, context, limit) do
    args = ["--no-heading", "--line-number", "--color", "never"]
    args = if ignore_case?, do: ["-i" | args], else: args
    args = if literal?, do: ["-F" | args], else: args
    args = if context > 0, do: ["-C", to_string(context) | args], else: args
    args = if glob, do: ["--glob", glob | args], else: args
    args = args ++ [pattern, path]

    case System.cmd("rg", args, stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true) |> Enum.take(limit)
      {_, 1} -> []
      {err, _} -> {:error, err}
    end
  end

  defp fallback_search(pattern, path, ignore_case?, limit) do
    compile_opts = if ignore_case?, do: [:caseless], else: []

    case Regex.compile(Regex.escape(pattern), compile_opts) do
      {:ok, regex} -> walk_and_match(path, regex, limit)
      {:error, _} -> []
    end
  end

  defp walk_and_match(path, regex, limit) do
    path
    |> all_files()
    |> Enum.flat_map(&match_file(&1, regex))
    |> Enum.take(limit)
  end

  defp all_files(path) do
    case_result =
      case File.stat(path) do
        {:ok, %File.Stat{type: :regular}} -> [path]
        {:ok, %File.Stat{type: :directory}} -> Path.wildcard(Path.join(path, "**/*"))
        _ -> []
      end

    Enum.filter(case_result, &regular?/1)
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
