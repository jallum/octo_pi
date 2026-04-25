defmodule OctoPi.Coder.Tools.Ls do
  @moduledoc """
  `ls` built-in tool. Non-recursive directory listing. Each entry
  is rendered as `"<name>[/]  <size>"` (trailing slash marks
  directories).
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  @default_limit 500

  @doc "Build a `%Tool{}` rooted at `cwd` — paths are resolved against it and escapes rejected."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "ls",
      label: "List directory",
      description:
        "List directory contents. Returns entries sorted alphabetically, with '/' suffix for directories. " <>
          "Includes dotfiles. Output is truncated to #{@default_limit} entries.",
      prompt_snippet: "List directory contents",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Directory to list (default: current directory)."},
          "limit" => %{
            "type" => "integer",
            "description" => "Maximum number of entries to return (default: #{@default_limit})."
          }
        },
        "required" => ["path"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path} = args, _abort_ref, _on_update) do
    _cwd = Map.fetch!(args, "_cwd")
    limit = Map.get(args, "limit", @default_limit)

    with {:ok, %File.Stat{type: :directory}} <- File.stat(path),
         {:ok, entries} <- File.ls(path) do
      entries = Enum.take(entries, limit)
      text = render(path, entries)

      {:ok,
       %Result{
         content: [%Content.Text{text: text}],
         details: %{path: path, count: length(entries)}
       }}
    else
      {:ok, %File.Stat{type: type}} ->
        {:ok,
         %Result{
           content: [%Content.Text{text: "path is not a directory (#{type}): #{path}"}],
           is_error?: true
         }}

      {:error, reason} ->
        {:ok,
         %Result{
           content: [%Content.Text{text: "ls failed: #{inspect(reason)} (#{path})"}],
           is_error?: true
         }}
    end
  end

  defp render(_path, []), do: "(empty directory)"

  defp render(path, entries) do
    entries
    |> Enum.sort()
    |> Enum.map_join("\n", &render_entry(path, &1))
  end

  defp render_entry(parent, name) do
    full = Path.join(parent, name)

    case File.stat(full) do
      {:ok, %File.Stat{type: :directory}} -> "#{name}/"
      {:ok, %File.Stat{type: :regular, size: size}} -> "#{name}  #{size}"
      {:ok, %File.Stat{type: type}} -> "#{name}  (#{type})"
      {:error, _} -> "#{name}  (?)"
    end
  end
end
