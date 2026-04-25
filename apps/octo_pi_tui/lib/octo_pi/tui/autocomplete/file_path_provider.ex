defmodule OctoPi.TUI.Autocomplete.FilePathProvider do
  @moduledoc """
  Autocomplete provider for filesystem paths. Matches upstream
  pi-mono CombinedAutocompleteProvider's file-path completion
  (tmp/pi-mono/packages/tui/src/autocomplete.ts) via a native
  Elixir walker — no external `fd` dependency.

  Triggers on:

    * `@...` prefix at the start of input — strips the `@`, walks
      `cwd` recursively, and returns files + directories matching
      the rest of the input.
    * An absolute path (starts with `/`) anywhere in the input.

  Semantics:

    * Case-insensitive fuzzy matching (via `OctoPi.TUI.Fuzzy`) on
      relative paths from `cwd`.
    * Directories rank before files of equal score.
    * `.git` directories are excluded.
    * Hidden entries (starting with `.`) are included otherwise.
    * Paths containing spaces are quoted with double quotes in the
      returned suggestion value.
    * Symlinked directories are followed; symlinked files match by
      basename regardless of link type.

  The returned `OctoPi.TUI.Autocomplete.Suggestion.value` field is
  the quoted/unquoted relative path suitable for substitution back
  into the input; `label` is the unquoted display path.
  """

  @behaviour OctoPi.TUI.Autocomplete

  alias OctoPi.TUI.Autocomplete.Suggestion
  alias OctoPi.TUI.Fuzzy

  @type t :: %__MODULE__{cwd: String.t(), max_results: pos_integer()}

  defstruct cwd: ".", max_results: 50

  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      cwd: Keyword.get(opts, :cwd, File.cwd!()),
      max_results: Keyword.get(opts, :max_results, 50)
    }
  end

  @impl true
  def get_suggestions(%__MODULE__{cwd: cwd, max_results: limit}, input) when is_binary(input) do
    case extract_query(input) do
      {:at, query} -> suggest_from_cwd(cwd, query, limit)
      {:abs, query} -> suggest_absolute(query, limit)
      :none -> {:ok, []}
    end
  end

  # --- trigger extraction ---

  defp extract_query("@" <> rest), do: {:at, rest}
  defp extract_query("/" <> _ = path), do: {:abs, path}
  defp extract_query(_other), do: :none

  # --- absolute-path completion (complete a single path) ---

  defp suggest_absolute(query, limit) do
    {dir, basename} = split_tail(query)

    case File.ls(dir) do
      {:ok, entries} ->
        items =
          entries
          |> Enum.reject(&(&1 == ".git"))
          |> Enum.filter(&String.starts_with?(&1, basename))
          |> Enum.map(fn e -> {e, Path.join(dir, e)} end)
          |> Enum.sort_by(fn {_name, full} -> {file_rank(full), String.downcase(full)} end)
          |> Enum.take(limit)
          |> Enum.map(fn {_name, full} ->
            %Suggestion{label: full, value: quote_if_needed(full), description: nil}
          end)

        {:ok, items}

      _ ->
        {:ok, []}
    end
  end

  defp split_tail(path) do
    case :binary.match(path, "/") do
      :nomatch ->
        {".", path}

      _ ->
        dir = Path.dirname(path)
        base = Path.basename(path)
        {dir, base}
    end
  end

  # --- @ query: recursive walk + fuzzy rank ---

  defp suggest_from_cwd(cwd, query, limit) do
    entries = walk(cwd, cwd, 0)
    trimmed = String.trim(query)

    ranked =
      if trimmed == "" do
        Enum.sort_by(entries, fn {rel, is_dir} ->
          {if(is_dir, do: 0, else: 1), String.downcase(rel)}
        end)
      else
        rank_with_fuzzy(entries, trimmed)
      end

    items =
      ranked
      |> Enum.take(limit)
      |> Enum.map(fn {rel, _dir?} ->
        %Suggestion{label: rel, value: quote_if_needed(rel), description: nil}
      end)

    {:ok, items}
  end

  defp rank_with_fuzzy(entries, query) do
    entries
    |> Enum.map(fn {rel, is_dir} ->
      case Fuzzy.match(query, rel) do
        %{matches: true, score: s} -> {rel, is_dir, s}
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(fn {_rel, is_dir, score} ->
      {if(is_dir, do: 0, else: 1), score}
    end)
    |> Enum.map(fn {rel, dir?, _s} -> {rel, dir?} end)
  end

  # --- filesystem walker ---
  # Returns list of {relative_path_from_root, is_dir}. Excludes .git
  # directories entirely. Follows symlinks. Depth-bounded to keep
  # very large trees from exploding a single autocomplete call.

  @max_depth 8

  defp walk(_dir, _root, depth) when depth > @max_depth, do: []

  defp walk(dir, root, depth) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.reject(&(&1 == ".git"))
        |> Enum.flat_map(fn entry ->
          full = Path.join(dir, entry)
          rel = Path.relative_to(full, root)
          stat = File.stat(full)

          case stat do
            {:ok, %File.Stat{type: :directory}} ->
              [{rel <> "/", true} | walk(full, root, depth + 1)]

            {:ok, %File.Stat{type: _}} ->
              [{rel, false}]

            _ ->
              []
          end
        end)

      _ ->
        []
    end
  end

  defp file_rank(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory}} -> 0
      _ -> 1
    end
  end

  defp quote_if_needed(path) do
    if String.contains?(path, " "), do: "\"#{path}\"", else: path
  end
end
