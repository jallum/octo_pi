defmodule OctoPi.Coder.Tools.Edit do
  @moduledoc """
  `edit` built-in tool. Performs a targeted search-and-replace on
  a file. By default requires `old_string` to occur exactly once;
  set `replace_all: true` to substitute every occurrence.

  All edits go through `FileMutex` so concurrent edits on the same
  path serialize.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.FileMutex
  alias OctoPi.Coder.Tools.PathGuard

  @doc "Build a `%Tool{}` rooted at `cwd` — paths are resolved against it and escapes rejected."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "edit",
      label: "Edit file",
      description: "Replace occurrences of a string in a file.",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path (resolved against session cwd)."},
          "old_string" => %{"type" => "string"},
          "new_string" => %{"type" => "string"},
          "replace_all" => %{"type" => "boolean"}
        },
        "required" => ["path", "old_string", "new_string"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path} = args, _abort_ref, _on_update) do
    cwd = Map.fetch!(args, "_cwd")
    old = Map.fetch!(args, "old_string")
    new = Map.fetch!(args, "new_string")
    replace_all? = Map.get(args, "replace_all", false)

    case PathGuard.resolve_or_error(path, cwd) do
      {:error, %Result{} = r} ->
        {:ok, r}

      {:ok, abs_path} ->
        FileMutex.with_lock(abs_path, fn -> do_edit(abs_path, old, new, replace_all?) end)
    end
  end

  defp do_edit(path, old, new, replace_all?) do
    with {:ok, body} <- File.read(path),
         {:ok, updated, count} <- replace(body, old, new, replace_all?),
         :ok <- File.write(path, updated) do
      {:ok,
       %Result{
         content: [%Content.Text{text: "edited #{path} (#{count} replacement#{s(count)})"}],
         details: %{path: path, replacements: count}
       }}
    else
      {:error, reason} ->
        {:ok,
         %Result{
           content: [%Content.Text{text: error_text(reason, path)}],
           is_error?: true
         }}
    end
  end

  defp replace(body, old, new, true) do
    case String.split(body, old) do
      [_single] -> {:error, :not_found}
      parts -> {:ok, Enum.join(parts, new), length(parts) - 1}
    end
  end

  defp replace(body, old, new, false) do
    case String.split(body, old) do
      [_single] -> {:error, :not_found}
      [before, rest] -> {:ok, before <> new <> rest, 1}
      _multiple -> {:error, :not_unique}
    end
  end

  defp error_text(:not_found, path), do: "old_string not found in #{path}"

  defp error_text(:not_unique, path), do: "old_string matches multiple locations in #{path} — use replace_all: true"

  defp error_text(:enoent, path), do: "enoent: no such file or directory: #{path}"
  defp error_text(reason, path), do: "edit failed: #{inspect(reason)} (#{path})"

  defp s(1), do: ""
  defp s(_), do: "s"
end
