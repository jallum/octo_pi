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

  @doc "Build a `%Tool{}` registered under the agent."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "ls",
      label: "List directory",
      description: "List entries in a directory (non-recursive).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute path to a directory."}
        },
        "required" => ["path"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path}, _abort_ref, _on_update) do
    with {:ok, %File.Stat{type: :directory}} <- File.stat(path),
         {:ok, entries} <- File.ls(path) do
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
