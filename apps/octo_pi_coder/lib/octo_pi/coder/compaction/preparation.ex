defmodule OctoPi.Coder.Compaction.Preparation do
  @moduledoc """
  Compaction-preparation step. Pure-function port of upstream
  `prepareCompaction` (`tmp/pi-mono/.../compaction/compaction.ts:614-689`).

  Given the path entries that would be compacted plus the active
  `Compaction.Settings`, returns a `%Preparation{}` describing
  exactly what the summarization step needs:

  - `first_kept_entry_id`: id of the first entry to keep
  - `messages_to_summarize`: messages destined for the summary
  - `turn_prefix_messages`: only populated on a split-turn cut
  - `split_turn?`: whether the cut lands inside a turn
  - `tokens_before`: rebuilt-context token count (NOT the
    trigger-time value)
  - `previous_summary`: optional prior `CompactionEntry.summary`
  - `file_ops`: extracted `Compaction.FileOps` (carried over from
    the previous compaction's `details` if it wasn't `from_hook?`)
  - `settings`: the settings used (echoed for downstream)

  Returns `nil` (mirroring upstream's `undefined`) when the path
  ends in a compaction or the cut would land on an entry without
  an id (session needs migration).
  """

  alias OctoPi.Coder.Compaction.{CutPoint, FileOps, Settings, Tokens}
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager

  @enforce_keys [
    :first_kept_entry_id,
    :messages_to_summarize,
    :turn_prefix_messages,
    :split_turn?,
    :tokens_before,
    :file_ops,
    :settings
  ]
  defstruct [
    :first_kept_entry_id,
    :messages_to_summarize,
    :turn_prefix_messages,
    :split_turn?,
    :tokens_before,
    :previous_summary,
    :file_ops,
    :settings
  ]

  @type t :: %__MODULE__{
          first_kept_entry_id: String.t(),
          messages_to_summarize: [term()],
          turn_prefix_messages: [term()],
          split_turn?: boolean(),
          tokens_before: non_neg_integer(),
          previous_summary: String.t() | nil,
          file_ops: FileOps.t(),
          settings: Settings.t()
        }

  @spec prepare([Entry.t()], Settings.t()) :: t() | nil
  def prepare([], _settings), do: nil

  def prepare(path_entries, %Settings{} = settings) when is_list(path_entries) do
    cond do
      ends_with_compaction?(path_entries) ->
        nil

      true ->
        do_prepare(path_entries, settings)
    end
  end

  defp ends_with_compaction?(entries) do
    case List.last(entries) do
      %Entry.Compaction{} -> true
      _ -> false
    end
  end

  defp do_prepare(path_entries, settings) do
    tuple = List.to_tuple(path_entries)
    end_index = tuple_size(tuple)

    {prev_compaction_index, previous_summary, boundary_start} =
      scan_previous_compaction_from(tuple, end_index - 1)

    rebuilt = SessionManager.build_context_from_path(path_entries)
    tokens_before = Tokens.estimate_context_tokens(rebuilt.messages).tokens

    cut =
      CutPoint.find_cut_point(
        path_entries,
        boundary_start,
        end_index,
        settings.keep_recent_tokens
      )

    first_kept = elem(tuple, cut.first_kept_entry_index)

    case entry_id(first_kept) do
      nil ->
        nil

      first_kept_entry_id ->
        history_end =
          if cut.split_turn?, do: cut.turn_start_index, else: cut.first_kept_entry_index

        messages_to_summarize = slice_messages(tuple, boundary_start, history_end)

        turn_prefix_messages =
          if cut.split_turn? do
            slice_messages(tuple, cut.turn_start_index, cut.first_kept_entry_index)
          else
            []
          end

        file_ops =
          messages_to_summarize
          |> Enum.reduce(prev_file_ops(tuple, prev_compaction_index), &FileOps.extract(&1, &2))
          |> then(fn ops ->
            Enum.reduce(turn_prefix_messages, ops, &FileOps.extract(&1, &2))
          end)

        %__MODULE__{
          first_kept_entry_id: first_kept_entry_id,
          messages_to_summarize: messages_to_summarize,
          turn_prefix_messages: turn_prefix_messages,
          split_turn?: cut.split_turn?,
          tokens_before: tokens_before,
          previous_summary: previous_summary,
          file_ops: file_ops,
          settings: settings
        }
    end
  end

  # Walk backwards looking for the most recent CompactionEntry on
  # the path. When found, surface its summary and locate the index
  # of `first_kept_entry_id` (falling back to "just past the
  # compaction" if the id has gone missing — matches upstream).
  defp scan_previous_compaction_from(_tuple, i) when i < 0, do: {-1, nil, 0}

  defp scan_previous_compaction_from(tuple, i) do
    case elem(tuple, i) do
      %Entry.Compaction{} = comp ->
        boundary = first_kept_index(tuple, comp.first_kept_entry_id, i)
        {i, comp.summary, boundary}

      _ ->
        scan_previous_compaction_from(tuple, i - 1)
    end
  end

  defp first_kept_index(tuple, target_id, prev_compaction_index) do
    end_index = tuple_size(tuple)

    Enum.reduce_while(0..(end_index - 1)//1, prev_compaction_index + 1, fn i, default ->
      case entry_id(elem(tuple, i)) do
        ^target_id -> {:halt, i}
        _ -> {:cont, default}
      end
    end)
  end

  defp slice_messages(_tuple, start, stop) when start >= stop, do: []

  defp slice_messages(tuple, start, stop) do
    Enum.flat_map(start..(stop - 1)//1, fn i ->
      entry = elem(tuple, i)

      case entry do
        %Entry.Compaction{} -> []
        _ -> SessionManager.entry_to_messages(entry)
      end
    end)
  end

  defp prev_file_ops(_tuple, -1), do: FileOps.new()

  defp prev_file_ops(tuple, index) do
    case elem(tuple, index) do
      %Entry.Compaction{from_hook: true} ->
        FileOps.new()

      %Entry.Compaction{details: %{} = details} ->
        carry_details(details)

      _ ->
        FileOps.new()
    end
  end

  defp carry_details(details) do
    read = list_strings(Map.get(details, "readFiles", []))
    edited = list_strings(Map.get(details, "modifiedFiles", []))

    %FileOps{
      read: MapSet.new(read),
      edited: MapSet.new(edited),
      written: MapSet.new()
    }
  end

  defp list_strings(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp list_strings(_), do: []

  defp entry_id(%Entry.Passthrough{raw: raw}), do: raw["id"]
  defp entry_id(entry), do: Map.get(entry, :id)
end
