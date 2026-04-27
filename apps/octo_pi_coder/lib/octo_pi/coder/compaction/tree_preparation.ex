defmodule OctoPi.Coder.Compaction.TreePreparation do
  @moduledoc """
  Prepared data for a tree-navigation operation passed in the
  `:session_before_tree` event. Extensions may inspect or cancel.

  `user_wants_summary` is three-valued (mirrors the three UI choices at
  `tmp/pi-mono/.../modes/interactive/interactive-mode.ts:4129`):
    * `:no`                    — skip summarization
    * `:yes`                   — summarize with default instructions
    * `{:yes, instructions}`   — summarize with caller-supplied instructions
  """

  alias OctoPi.Coder.Session.Entry

  @type wants_summary :: :no | :yes | {:yes, String.t()}

  @enforce_keys [:target_id, :entries_to_summarize, :user_wants_summary]
  defstruct [
    :target_id,
    :old_leaf_id,
    :common_ancestor_id,
    :entries_to_summarize,
    :user_wants_summary
  ]

  @type t :: %__MODULE__{
          target_id: String.t(),
          old_leaf_id: String.t() | nil,
          common_ancestor_id: String.t() | nil,
          entries_to_summarize: [Entry.t()],
          user_wants_summary: wants_summary()
        }
end
