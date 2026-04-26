defmodule OctoPi.Coder.Compaction.CutPoint do
  @moduledoc """
  Cut-point selection for compaction. Ports
  `tmp/pi-mono/.../compaction/compaction.ts`:

  - `findValidCutPoints`  (lines 299-337)
  - `findTurnStartIndex`  (lines 344-359)
  - `findCutPoint`        (lines 386-448)

  Algorithm: walk backwards from the newest entry accumulating
  per-message token estimates; once `keep_recent_tokens` is hit,
  forward-scan to the nearest valid cut point. Valid cuts are
  user / assistant message entries, plus `branch_summary` and
  `custom_message` entries (treated as user-role messages).
  Tool-result messages are NEVER valid cut points — they must
  follow their tool call.

  After picking the cut, scan backwards to absorb any non-message
  entries (model_change, thinking_level_change, …) that should
  travel with the kept window. A pre-existing `compaction` entry
  is treated as a hard left-edge.

  Per-message token estimates are delegated to
  `OctoPi.Coder.Compaction.Tokens.estimate_tokens/1` (which accepts
  both typed structs and raw `entry.message` maps). Adding
  bashExecution / branchSummary / compactionSummary message-role
  heads to that estimator is opi-ixp.43.
  """

  alias OctoPi.Coder.Compaction.Tokens
  alias OctoPi.Coder.Session.Entry

  defmodule Result do
    @moduledoc """
    Mirror of upstream `CutPointResult` (compaction.ts:361-368).
    `split_turn?` is true when the cut lands inside a turn — the
    caller will need a separate summary path for the half it drops.
    """
    @enforce_keys [:first_kept_entry_index, :turn_start_index, :split_turn?]
    defstruct [:first_kept_entry_index, :turn_start_index, :split_turn?]

    @type t :: %__MODULE__{
            first_kept_entry_index: integer(),
            turn_start_index: integer(),
            split_turn?: boolean()
          }
  end

  # ---- find_turn_start_index ---------------------------------------------

  @doc """
  Walk backwards from `entry_index` looking for the entry that
  started the current turn — a user/bashExecution message, a
  `BranchSummary` entry, or a `CustomMessage` entry. Returns -1
  if no such entry exists at or after `start_index`.
  """
  @spec find_turn_start_index([Entry.t()], integer(), non_neg_integer()) :: integer()
  def find_turn_start_index(entries, entry_index, start_index) when is_list(entries) do
    do_find_turn_start_index(List.to_tuple(entries), entry_index, start_index)
  end

  defp do_find_turn_start_index(_tuple, i, start_index) when i < start_index, do: -1

  defp do_find_turn_start_index(tuple, i, start_index) do
    case turn_start?(elem(tuple, i)) do
      true -> i
      false -> do_find_turn_start_index(tuple, i - 1, start_index)
    end
  end

  defp turn_start?(%Entry.BranchSummary{}), do: true
  defp turn_start?(%Entry.CustomMessage{}), do: true
  defp turn_start?(%Entry.Message{message: %{"role" => "user"}}), do: true
  defp turn_start?(%Entry.Message{message: %{"role" => "bashExecution"}}), do: true
  defp turn_start?(_), do: false

  # ---- find_cut_point ----------------------------------------------------

  @doc """
  Find the cut point that keeps roughly `keep_recent_tokens` from
  the tail. Considers entries in `[start_index, end_index)`. Returns
  `start_index` (and no split) when no valid cut points exist.
  """
  @spec find_cut_point([Entry.t()], non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          Result.t()
  def find_cut_point(entries, start_index, end_index, keep_recent_tokens)
      when is_list(entries) do
    tuple = List.to_tuple(entries)
    cut_points = find_valid_cut_points(tuple, start_index, end_index)
    do_find_cut_point(tuple, cut_points, start_index, end_index, keep_recent_tokens)
  end

  defp do_find_cut_point(_tuple, [], start_index, _end_index, _keep) do
    %Result{first_kept_entry_index: start_index, turn_start_index: -1, split_turn?: false}
  end

  defp do_find_cut_point(tuple, [first_cut | _] = cut_points, start_index, end_index, keep) do
    cut_index = walk_for_cut(tuple, end_index - 1, start_index, 0, keep, cut_points, first_cut)
    cut_index = absorb_leading_non_messages(tuple, cut_index, start_index)
    build_result(tuple, cut_index, start_index)
  end

  # Walk newest → oldest, accumulating token estimates from message
  # entries; once we cross the keep budget, snap forward to the
  # closest cut point at or after the current index.
  defp walk_for_cut(_tuple, i, start_index, _acc, _keep, _cuts, default) when i < start_index,
    do: default

  defp walk_for_cut(tuple, i, start_index, acc, keep, cuts, default) do
    entry = elem(tuple, i)

    case entry do
      %Entry.Message{} ->
        acc = acc + estimate_message_tokens(entry)

        if acc >= keep do
          closest_cut_at_or_after(cuts, i, default)
        else
          walk_for_cut(tuple, i - 1, start_index, acc, keep, cuts, default)
        end

      _ ->
        walk_for_cut(tuple, i - 1, start_index, acc, keep, cuts, default)
    end
  end

  defp closest_cut_at_or_after([c | _], i, _default) when c >= i, do: c
  defp closest_cut_at_or_after([_ | rest], i, default), do: closest_cut_at_or_after(rest, i, default)
  defp closest_cut_at_or_after([], _i, default), do: default

  # Pull any non-message entries (model/thinking changes, custom,
  # session_info, label) that immediately precede the cut into the
  # kept window. Stop at a compaction boundary or any message entry.
  defp absorb_leading_non_messages(_tuple, cut_index, start_index) when cut_index <= start_index,
    do: cut_index

  defp absorb_leading_non_messages(tuple, cut_index, start_index) do
    case elem(tuple, cut_index - 1) do
      %Entry.Compaction{} -> cut_index
      %Entry.Message{} -> cut_index
      %Entry.BranchSummary{} -> cut_index
      %Entry.CustomMessage{} -> cut_index
      _ -> absorb_leading_non_messages(tuple, cut_index - 1, start_index)
    end
  end

  defp build_result(tuple, cut_index, start_index) do
    cut_entry = elem(tuple, cut_index)
    is_user = match?(%Entry.Message{message: %{"role" => "user"}}, cut_entry)

    turn_start =
      if is_user do
        -1
      else
        do_find_turn_start_index(tuple, cut_index, start_index)
      end

    %Result{
      first_kept_entry_index: cut_index,
      turn_start_index: turn_start,
      split_turn?: not is_user and turn_start != -1
    }
  end

  # ---- valid cut points --------------------------------------------------

  defp find_valid_cut_points(tuple, start_index, end_index) do
    Enum.reduce(start_index..(end_index - 1)//1, [], fn i, acc ->
      if cut_point?(elem(tuple, i)), do: [i | acc], else: acc
    end)
    |> Enum.reverse()
  end

  defp cut_point?(%Entry.Message{message: %{"role" => role}})
       when role in ["user", "assistant", "bashExecution", "custom",
                     "branchSummary", "compactionSummary"],
       do: true

  defp cut_point?(%Entry.BranchSummary{}), do: true
  defp cut_point?(%Entry.CustomMessage{}), do: true
  defp cut_point?(_), do: false

  defp estimate_message_tokens(%Entry.Message{message: m}), do: Tokens.estimate_tokens(m)
  defp estimate_message_tokens(_), do: 0
end
