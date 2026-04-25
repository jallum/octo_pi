defmodule OctoPi.Coder.Tools.Edit do
  @moduledoc """
  `edit` built-in tool. Performs one or more exact text replacements
  on a file in a single call. Every `edits[].old_text` must match a
  unique, non-overlapping region of the original file; overlapping or
  ambiguous edits are rejected.

  All edits go through `FileMutex` so concurrent edits on the same
  path serialize.
  """

  @behaviour OctoPi.Agent.Tool.Handler

  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.Coder.FileMutex


  @doc "Build a `%Tool{}` rooted at `cwd` — paths are resolved against it and escapes rejected."
  @spec tool(String.t()) :: Tool.t()
  def tool(cwd) when is_binary(cwd) do
    %Tool{
      name: "edit",
      label: "Edit file",
      description:
        "Edit a single file using exact text replacement. Every edits[].old_text must match a unique, " <>
          "non-overlapping region of the original file. If two changes affect the same block or nearby lines, " <>
          "merge them into one edit instead of emitting overlapping edits.",
      prompt_snippet:
        "Make precise file edits with exact text replacement, including multiple disjoint edits in one call",
      parameters: %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Path to the file to edit (relative or absolute)."},
          "edits" => %{
            "type" => "array",
            "description" =>
              "List of targeted replacements to apply. Each old_text must be unique and non-overlapping.",
            "items" => %{
              "type" => "object",
              "properties" => %{
                "old_text" => %{
                  "type" => "string",
                  "description" =>
                    "Exact text to replace. Must appear exactly once in the file and must not overlap with other edits."
                },
                "new_text" => %{
                  "type" => "string",
                  "description" => "Replacement text."
                }
              },
              "required" => ["old_text", "new_text"],
              "additionalProperties" => false
            }
          }
        },
        "required" => ["path", "edits"]
      },
      prepare_arguments: fn args -> Map.put(args, "_cwd", cwd) end,
      handler: __MODULE__
    }
  end

  @impl true
  def execute(_id, %{"path" => path, "edits" => edits} = args, _abort_ref, _on_update) do
    cwd = Map.fetch!(args, "_cwd")

    abs_path = Path.expand(path, cwd)
    FileMutex.with_lock(abs_path, fn -> do_edit(abs_path, edits) end)
  end

  defp do_edit(path, edits) do
    with {:ok, body} <- File.read(path),
         {:ok, updated, count} <- apply_edits(body, edits),
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

  # Apply all edits against the original body.
  # Each old_text must appear exactly once; no two edits may overlap.
  defp apply_edits(body, edits) do
    # Resolve each edit to a byte range in the original body.
    with {:ok, ranges} <- resolve_ranges(body, edits) do
      check_overlaps(ranges, edits, body)
    end
  end

  defp resolve_ranges(body, edits) do
    edits
    |> Enum.reduce_while({:ok, []}, fn edit, {:ok, acc} ->
      old_text = Map.fetch!(edit, "old_text")

      case find_unique(body, old_text) do
        {:ok, offset} -> {:cont, {:ok, [{offset, byte_size(old_text), edit} | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> case do
      {:ok, ranges} -> {:ok, Enum.reverse(ranges)}
      err -> err
    end
  end

  defp find_unique(body, old_text) do
    case find_all_offsets(body, old_text, 0, []) do
      [] -> {:error, {:not_found, old_text}}
      [offset] -> {:ok, offset}
      _ -> {:error, {:not_unique, old_text}}
    end
  end

  defp find_all_offsets(body, pattern, start, acc) do
    psize = byte_size(pattern)
    bsize = byte_size(body)

    if start > bsize - psize do
      Enum.reverse(acc)
    else
      case :binary.match(body, pattern, scope: {start, bsize - start}) do
        :nomatch ->
          Enum.reverse(acc)

        {offset, _len} ->
          find_all_offsets(body, pattern, offset + 1, [offset | acc])
      end
    end
  end

  defp check_overlaps(ranges, _edits, body) do
    # Sort by offset; check that no edit's start falls within a prior edit's range.
    sorted = Enum.sort_by(ranges, fn {offset, _, _} -> offset end)

    case find_overlap(sorted) do
      {:error, _} = err ->
        err

      :ok ->
        count = length(sorted)
        updated = apply_sorted_ranges(body, sorted, 0, [])
        {:ok, updated, count}
    end
  end

  defp find_overlap([]), do: :ok
  defp find_overlap([_]), do: :ok

  defp find_overlap([{off_a, size_a, edit_a} | [{off_b, _size_b, _edit_b} | _] = rest]) do
    if off_b < off_a + size_a do
      {:error, {:overlapping_edits, Map.fetch!(edit_a, "old_text")}}
    else
      find_overlap(rest)
    end
  end

  # Walk the original body applying replacements in order, tracking
  # the current cursor in the original bytes.
  defp apply_sorted_ranges(body, [], cursor, acc) do
    tail = binary_part(body, cursor, byte_size(body) - cursor)
    IO.iodata_to_binary(Enum.reverse([tail | acc]))
  end

  defp apply_sorted_ranges(body, [{offset, size, edit} | rest], cursor, acc) do
    prefix = binary_part(body, cursor, offset - cursor)
    new_text = Map.fetch!(edit, "new_text")
    apply_sorted_ranges(body, rest, offset + size, [new_text, prefix | acc])
  end

  defp error_text({:not_found, old_text}, path), do: "old_text not found in #{path}: #{inspect(truncate(old_text, 60))}"

  defp error_text({:not_unique, old_text}, path),
    do: "old_text matches multiple locations in #{path}: #{inspect(truncate(old_text, 60))}"

  defp error_text({:overlapping_edits, old_text}, path),
    do: "overlapping edits in #{path} — merge nearby changes into one edit: #{inspect(truncate(old_text, 60))}"

  defp error_text(:enoent, path), do: "enoent: no such file or directory: #{path}"
  defp error_text(reason, path), do: "edit failed: #{inspect(reason)} (#{path})"

  defp truncate(str, max) when byte_size(str) > max, do: binary_part(str, 0, max) <> "…"
  defp truncate(str, _max), do: str

  defp s(1), do: ""
  defp s(_), do: "s"
end
