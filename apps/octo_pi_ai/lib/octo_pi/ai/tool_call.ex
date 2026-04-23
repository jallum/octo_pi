defmodule OctoPi.AI.ToolCall do
  @moduledoc """
  A tool-use content block in an assistant message.

  During streaming the provider fills `arguments` incrementally by
  reparsing the accumulated `partial_json` buffer. When the block
  finalizes, `partial_json` is dropped and `arguments` is considered
  authoritative.

  `thought_signature` is Google-specific opaque state for multi-turn
  continuity.
  """

  @enforce_keys [:id, :name]
  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          arguments: map(),
          thought_signature: String.t() | nil
        }

  defstruct [:id, :name, arguments: %{}, thought_signature: nil]
end
