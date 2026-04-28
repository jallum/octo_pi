defmodule OctoPi.Coder.Compaction.Result do
  @moduledoc """
  Outcome of a `OctoPi.Coder.Compaction.compact/2` call. Mirrors the
  upstream `CompactionResult` interface
  (`tmp/pi-mono/.../compaction/compaction.ts:102-109`).

  `details` is the wire-shape map (string keys `"readFiles"` /
  `"modifiedFiles"`) so callers can pour it straight into a
  `Session.Entry.Compaction.details` field without reshaping.
  """

  @enforce_keys [:summary, :first_kept_entry_id, :tokens_before]
  defstruct [:summary, :first_kept_entry_id, :tokens_before, :details]

  @type t :: %__MODULE__{
          summary: String.t(),
          first_kept_entry_id: String.t(),
          tokens_before: non_neg_integer(),
          details: %{optional(String.t()) => term()} | nil
        }
end
