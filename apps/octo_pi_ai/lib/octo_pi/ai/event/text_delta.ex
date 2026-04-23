defmodule OctoPi.AI.Event.TextDelta do
  @moduledoc "An incremental chunk of a text content block."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :delta, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          delta: String.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :delta, :partial]
end
