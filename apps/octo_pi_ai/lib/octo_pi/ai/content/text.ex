defmodule OctoPi.AI.Content.Text do
  @moduledoc """
  A text content block. `signature` is optional metadata some providers
  attach to a message (e.g. OpenAI Responses reasoning-item IDs).
  """

  @type t :: %__MODULE__{
          text: String.t(),
          signature: String.t() | nil
        }

  defstruct text: "", signature: nil
end
