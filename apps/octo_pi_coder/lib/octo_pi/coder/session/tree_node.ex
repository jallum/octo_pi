defmodule OctoPi.Coder.Session.TreeNode do
  @moduledoc """
  A node in the session tree returned by `SessionManager.get_tree/1`.
  Mirrors `SessionTreeNode` in
  `tmp/pi-mono/packages/coding-agent/src/core/session-manager.ts:152-160`.
  """

  alias OctoPi.Coder.Session.Entry

  @enforce_keys [:entry, :children]
  defstruct [:entry, :children, :label, :label_timestamp]

  @type t :: %__MODULE__{
          entry: Entry.t(),
          children: [t()],
          label: String.t() | nil,
          label_timestamp: String.t() | nil
        }
end
