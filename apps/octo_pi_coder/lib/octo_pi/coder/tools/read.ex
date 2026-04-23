defmodule OctoPi.Coder.Tools.Read do
  @moduledoc """
  `read` built-in tool. Reads (a slice of) a file from disk and
  returns its content as a text block. Large files are truncated
  with a `:details` map describing what was trimmed.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content

  @max_lines 10_000
  @max_bytes 512 * 1024

  @doc "Build a `%Tool{}` registered under the agent."
  @spec tool() :: Tool.t()
  def tool do
    %Tool{
      name: "read",
      label: "Read file",
      description: "Read a file's contents (optionally a line range).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute path to the file."},
          "offset" => %{"type" => "integer", "description" => "1-indexed start line."},
          "limit" => %{"type" => "integer", "description" => "Max number of lines to return."}
        },
        "required" => ["path"]
      },
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path} = args, _abort_ref, _on_update) do
    offset = Map.get(args, "offset")
    limit = Map.get(args, "limit")

    with :ok <- ensure_regular_file(path),
         {:ok, body} <- File.read(path) do
      {body, details} = slice_and_truncate(body, offset, limit)
      {:ok, %Result{content: [%Content.Text{text: body}], details: details}}
    else
      {:error, reason} -> {:ok, error_result(reason, path)}
    end
  end

  defp ensure_regular_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular}} -> :ok
      {:ok, %File.Stat{type: :directory}} -> {:error, :is_directory}
      {:ok, _} -> {:error, :not_regular_file}
      {:error, reason} -> {:error, reason}
    end
  end

  defp slice_and_truncate(body, offset, limit) do
    lines = String.split(body, "\n")
    total = length(lines) - 1

    sliced =
      lines
      |> maybe_drop(offset)
      |> maybe_take(limit)

    text = Enum.join(sliced, "\n")

    cond do
      byte_size(text) > @max_bytes ->
        {binary_part(text, 0, @max_bytes),
         %{
           truncated: true,
           truncated_by: :bytes,
           total_lines: total,
           output_lines: length(sliced)
         }}

      length(sliced) > @max_lines ->
        kept = Enum.take(sliced, @max_lines)

        {Enum.join(kept, "\n"),
         %{truncated: true, truncated_by: :lines, total_lines: total, output_lines: @max_lines}}

      true ->
        {text,
         %{
           truncated: false,
           truncated_by: nil,
           total_lines: total,
           output_lines: length(sliced)
         }}
    end
  end

  defp maybe_drop(lines, nil), do: lines
  defp maybe_drop(lines, offset) when is_integer(offset), do: Enum.drop(lines, max(offset - 1, 0))

  defp maybe_take(lines, nil), do: lines
  defp maybe_take(lines, limit) when is_integer(limit), do: Enum.take(lines, limit)

  defp error_result(reason, path) do
    msg =
      case reason do
        :is_directory -> "path is a directory: #{path}"
        :not_regular_file -> "path is not a regular file: #{path}"
        :enoent -> "enoent: no such file or directory: #{path}"
        :eacces -> "eacces: permission denied: #{path}"
        other -> "read failed: #{inspect(other)} (#{path})"
      end

    %Result{content: [%Content.Text{text: msg}], is_error?: true}
  end
end
