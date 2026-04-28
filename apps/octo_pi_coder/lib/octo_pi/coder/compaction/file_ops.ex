defmodule OctoPi.Coder.Compaction.FileOps do
  @moduledoc """
  File-operation tracking for compaction summaries. Pure-function port
  of `tmp/pi-mono/.../compaction/utils.ts:11-82`:

  - `new/0`           — `createFileOps`
  - `extract/2`       — `extractFileOpsFromMessage`
  - `compute_lists/1` — `computeFileLists`
  - `format/2`        — `formatFileOperations`

  Tracked tool calls are exactly `read`, `write`, `edit` — anything
  else (including the multi-edit family) is ignored, matching upstream.
  """

  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.ToolCall

  @type t :: %__MODULE__{
          read: MapSet.t(String.t()),
          written: MapSet.t(String.t()),
          edited: MapSet.t(String.t())
        }

  defstruct read: MapSet.new(), written: MapSet.new(), edited: MapSet.new()

  # MapSet.new() returns %MapSet{map: %{}} which Dialyzer types as
  # MapSet.t(_), not the parametric MapSet.t(String.t()). False positive.
  @dialyzer {:nowarn_function, new: 0}
  @spec new() :: t()
  def new, do: %__MODULE__{}

  # ---- extract -----------------------------------------------------------

  @doc """
  Walk an assistant message's tool calls, classifying any with a
  string `path` argument by tool name. Non-assistant messages and
  malformed blocks are ignored.
  """
  @spec extract(struct() | map(), t()) :: t()
  def extract(%Assistant{content: blocks}, %__MODULE__{} = ops) when is_list(blocks),
    do: Enum.reduce(blocks, ops, &classify/2)

  # Raw decoded-JSON assistant maps (as held by `Session.Entry.Message`).
  def extract(%{"role" => "assistant", "content" => blocks}, %__MODULE__{} = ops) when is_list(blocks),
    do: Enum.reduce(blocks, ops, &classify/2)

  def extract(_other, %__MODULE__{} = ops), do: ops

  defp classify(%ToolCall{name: "read", arguments: %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | read: MapSet.put(ops.read, path)}

  defp classify(%ToolCall{name: "write", arguments: %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | written: MapSet.put(ops.written, path)}

  defp classify(%ToolCall{name: "edit", arguments: %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | edited: MapSet.put(ops.edited, path)}

  defp classify(%{"type" => "toolCall", "name" => "read", "arguments" => %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | read: MapSet.put(ops.read, path)}

  defp classify(%{"type" => "toolCall", "name" => "write", "arguments" => %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | written: MapSet.put(ops.written, path)}

  defp classify(%{"type" => "toolCall", "name" => "edit", "arguments" => %{"path" => path}}, ops) when is_binary(path),
    do: %{ops | edited: MapSet.put(ops.edited, path)}

  defp classify(_block, ops), do: ops

  # ---- compute_lists -----------------------------------------------------

  @doc """
  Collapse a `FileOps` into final lists. `modified_files` is the union
  of `written` ∪ `edited` (alphabetical); `read_files` is `read` minus
  `modified_files` (also alphabetical).
  """
  @spec compute_lists(t()) :: %{read_files: [String.t()], modified_files: [String.t()]}
  def compute_lists(%__MODULE__{read: r, written: w, edited: e}) do
    modified = MapSet.union(w, e)

    %{
      read_files: r |> MapSet.difference(modified) |> Enum.sort(),
      modified_files: Enum.sort(modified)
    }
  end

  # ---- format ------------------------------------------------------------

  @doc """
  Render `read_files` / `modified_files` as the upstream XML blocks
  used inside compaction summaries. Returns `""` when both lists are
  empty (callers concatenate unconditionally).
  """
  @spec format([String.t()], [String.t()]) :: String.t()
  def format([], []), do: ""

  def format(read_files, modified_files) do
    sections =
      []
      |> maybe_section("read-files", read_files)
      |> maybe_section("modified-files", modified_files)
      |> Enum.reverse()

    "\n\n" <> Enum.join(sections, "\n\n")
  end

  defp maybe_section(acc, _tag, []), do: acc

  defp maybe_section(acc, tag, files), do: ["<#{tag}>\n" <> Enum.join(files, "\n") <> "\n</#{tag}>" | acc]
end
