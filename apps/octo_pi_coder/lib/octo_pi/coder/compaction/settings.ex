defmodule OctoPi.Coder.Compaction.Settings do
  @moduledoc """
  Compaction-subsystem settings. Defaults mirror upstream
  `DEFAULT_COMPACTION_SETTINGS` in
  `tmp/pi-mono/.../compaction/compaction.ts:121-125`.

  This is the seed schema; A4 (`opi-ixp.4`) extends it with project /
  global JSON discovery and deep-merge.
  """

  @type t :: %__MODULE__{
          enabled: boolean(),
          reserve_tokens: non_neg_integer(),
          keep_recent_tokens: non_neg_integer()
        }

  defstruct enabled: true, reserve_tokens: 16_384, keep_recent_tokens: 20_000

  @spec default() :: t()
  def default, do: %__MODULE__{}
end
