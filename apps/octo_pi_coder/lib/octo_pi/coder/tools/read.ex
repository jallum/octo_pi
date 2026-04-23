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
  alias OctoPi.Coder.Tools.PathGuard

  @max_lines 10_000
  @max_bytes 512 * 1024

  @doc "Build a `%Tool{}` rooted at `cwd` — paths are resolved against it and escapes rejected."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "read",
      label: "Read file",
      description: "Read a file's contents (optionally a line range).",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path (resolved against session cwd)."},
          "offset" => %{"type" => "integer", "description" => "1-indexed start line."},
          "limit" => %{"type" => "integer", "description" => "Max number of lines to return."}
        },
        "required" => ["path"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path} = args, _abort_ref, _on_update) do
    cwd = Map.fetch!(args, "_cwd")
    offset = Map.get(args, "offset")
    limit = Map.get(args, "limit")

    with {:ok, path} <- PathGuard.resolve_or_error(path, cwd),
         :ok <- ensure_regular_file(path),
         {:ok, body} <- File.read(path) do
      {body, details} = slice_and_truncate(body, offset, limit)
      {:ok, %Result{content: [%Content.Text{text: body}], details: details}}
    else
      {:error, %Result{} = guard_result} -> {:ok, guard_result}
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
    # Keep the raw split (which preserves the trailing newline via a
    # trailing empty element) for output. Compute the actual line
    # count separately so files without a trailing newline report
    # the correct total.
    raw = split_raw(body)
    total = line_count(raw)

    sliced =
      raw
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
           output_lines: line_count(sliced)
         }}

      line_count(sliced) > @max_lines ->
        kept = Enum.take(sliced, @max_lines)

        {Enum.join(kept, "\n"),
         %{truncated: true, truncated_by: :lines, total_lines: total, output_lines: @max_lines}}

      true ->
        {text,
         %{
           truncated: false,
           truncated_by: nil,
           total_lines: total,
           output_lines: line_count(sliced)
         }}
    end
  end

  defp split_raw(""), do: []
  defp split_raw(body), do: String.split(body, "\n")

  # Counts real lines, ignoring the trailing empty element that
  # `String.split/2` produces when the file ends with `\n`. An empty
  # file is 0 lines; "a" is 1 line; "a\n" is 1 line; "a\nb" is 2
  # lines; "a\nb\n" is 2 lines.
  defp line_count([]), do: 0

  defp line_count(lines) do
    if List.last(lines) == "", do: length(lines) - 1, else: length(lines)
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
