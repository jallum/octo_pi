defmodule OctoPi.Coder.Compaction.BranchSummarization do
  @moduledoc """
  Prepare session entries for branch summarization. Two-pass design:

  1. **First pass** — scan ALL entries for pi-generated `branch_summary`
     entries (`from_hook != true`) and accumulate their
     `details.readFiles` / `details.modifiedFiles` into `file_ops`.
     This ensures cumulative file tracking even when older context
     falls outside the token budget.

  2. **Second pass** — walk newest → oldest, adding messages to the
     output list until `token_budget` is reached. Summary entries
     (`compaction`, `branch_summary`) are included even when they
     would overflow the budget if `total_tokens < 0.9 × token_budget`;
     then the walk stops.  `tool_result` messages are always skipped.

  Returns a `%BranchSummarization{}` with:
    - `:messages` — collected messages in chronological (oldest-first) order
    - `:file_ops`  — cumulative `%FileOps{}` from both passes
    - `:total_tokens` — estimated tokens for the included messages

  Port of `prepareBranchEntries`
  (`tmp/pi-mono/.../compaction/branch-summarization.ts:185-237`).
  """

  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Tokens
  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Entry

  @enforce_keys [:messages, :file_ops, :total_tokens]
  defstruct [:messages, :file_ops, :total_tokens]

  @type t :: %__MODULE__{
          messages: [term()],
          file_ops: FileOps.t(),
          total_tokens: non_neg_integer()
        }

  @doc """
  Prepare `entries` (chronological order) for branch summarization.

  `token_budget` is the maximum tokens to include; `0` means no limit.
  """
  @spec prepare([Entry.t()], non_neg_integer()) :: t()
  def prepare(entries, token_budget \\ 0) when is_list(entries) and is_integer(token_budget) do
    file_ops = first_pass(entries, FileOps.new())
    {messages, file_ops, total_tokens} = second_pass(entries, file_ops, token_budget)
    %__MODULE__{messages: messages, file_ops: file_ops, total_tokens: total_tokens}
  end

  # ---- first pass ----------------------------------------------------------

  defp first_pass(entries, ops) do
    Enum.reduce(entries, ops, fn
      %Entry.BranchSummary{from_hook: hook, details: details}, acc
      when hook != true and is_map(details) ->
        acc
        |> merge_read_files(Map.get(details, "readFiles", []))
        |> merge_modified_files(Map.get(details, "modifiedFiles", []))

      _other, acc ->
        acc
    end)
  end

  defp merge_read_files(ops, files) when is_list(files) do
    Enum.reduce(files, ops, fn
      f, acc when is_binary(f) -> %{acc | read: MapSet.put(acc.read, f)}
      _, acc -> acc
    end)
  end

  defp merge_modified_files(ops, files) when is_list(files) do
    Enum.reduce(files, ops, fn
      f, acc when is_binary(f) -> %{acc | edited: MapSet.put(acc.edited, f)}
      _, acc -> acc
    end)
  end

  # ---- second pass ---------------------------------------------------------

  defp second_pass(entries, file_ops, token_budget) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({[], file_ops, 0}, fn entry, {msgs, ops, total} ->
      case message_from_entry(entry) do
        nil ->
          {:cont, {msgs, ops, total}}

        msg ->
          ops = FileOps.extract(msg, ops)
          tokens = Tokens.estimate_tokens(msg)

          if token_budget > 0 and total + tokens > token_budget do
            if summary_entry?(entry) and total < token_budget * 0.9 do
              {:halt, {[msg | msgs], ops, total + tokens}}
            else
              {:halt, {msgs, ops, total}}
            end
          else
            {:cont, {[msg | msgs], ops, total + tokens}}
          end
      end
    end)
  end

  defp summary_entry?(%Entry.Compaction{}), do: true
  defp summary_entry?(%Entry.BranchSummary{}), do: true
  defp summary_entry?(_), do: false

  # ---- entry → message conversion -----------------------------------------

  defp message_from_entry(%Entry.Message{message: %{"role" => "toolResult"}}), do: nil
  defp message_from_entry(%Entry.Message{message: msg}), do: msg

  defp message_from_entry(%Entry.BranchSummary{summary: s, from_id: from_id, timestamp: ts}) do
    BranchSummaryMessage.new(s, from_id, ts || 0)
  end

  defp message_from_entry(%Entry.Compaction{summary: s, tokens_before: tb, timestamp: ts}) do
    CompactionSummaryMessage.new(s, tb || 0, ts || 0)
  end

  defp message_from_entry(_), do: nil
end
