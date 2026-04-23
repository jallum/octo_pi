defmodule OctoPi.AI.Content.Thinking do
  @moduledoc """
  A thinking / reasoning content block.

  `signature` carries opaque provider state required for multi-turn
  replay. When `redacted?` is true, the provider returned a redacted
  thinking block and `signature` holds the encrypted payload; `thinking`
  will be a placeholder like `"[Reasoning redacted]"`.
  """

  @type t :: %__MODULE__{
          thinking: String.t(),
          signature: String.t() | nil,
          redacted?: boolean()
        }

  defstruct thinking: "", signature: nil, redacted?: false
end
