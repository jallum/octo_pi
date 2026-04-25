defmodule OctoPi.Coder.ResourceLoader.ContextFiles do
  @moduledoc """
  Discovers and loads CLAUDE.md / AGENTS.md context files.

  Mirrors upstream pi-mono's `loadProjectContextFiles` in
  `resource-loader.ts`. Walks from cwd upward to the filesystem root,
  collecting one context file per directory (AGENTS.md preferred over
  CLAUDE.md), then prepends the global context file from `agent_dir`
  (defaults to `~/.pi/`).
  """

  @candidates ["AGENTS.md", "CLAUDE.md"]

  @type context_file :: %{path: String.t(), content: String.t()}

  @doc """
  Load all context files for `cwd`.

  `agent_dir` is the global config directory (e.g. `~/.pi/`). Pass
  `nil` to skip global context loading.

  Returns a list of `%{path: path, content: content}` maps, ordered:
  global file first, then ancestor chain root → cwd.
  """
  @spec load_all(String.t(), String.t() | nil) :: [context_file()]
  def load_all(cwd, agent_dir) do
    global = if agent_dir, do: load_from_dir(agent_dir)
    global_paths = if global, do: MapSet.new([global.path]), else: MapSet.new()
    global_list = if global, do: [global], else: []
    ancestor_files = walk_ancestors(cwd, global_paths)
    global_list ++ ancestor_files
  end

  defp walk_ancestors(cwd, seen) do
    cwd
    |> stream_ancestors()
    |> Enum.reduce({[], seen}, &accumulate_dir/2)
    |> elem(0)
  end

  defp accumulate_dir(dir, {acc, seen_paths}) do
    case load_from_dir(dir) do
      nil -> {acc, seen_paths}
      %{path: path} = file -> accumulate_file(file, path, acc, seen_paths)
    end
  end

  defp accumulate_file(file, path, acc, seen_paths) do
    if MapSet.member?(seen_paths, path) do
      {acc, seen_paths}
    else
      {[file | acc], MapSet.put(seen_paths, path)}
    end
  end

  # Emit dirs from cwd up to root (cwd first, root last).
  defp stream_ancestors(cwd) do
    Stream.unfold(Path.expand(cwd), fn
      nil ->
        nil

      dir ->
        parent = Path.dirname(dir)
        next = if parent == dir, do: nil, else: parent
        {dir, next}
    end)
  end

  defp load_from_dir(dir) do
    Enum.find_value(@candidates, fn filename ->
      path = Path.join(dir, filename)

      case File.read(path) do
        {:ok, content} -> %{path: path, content: content}
        {:error, _} -> nil
      end
    end)
  end
end
