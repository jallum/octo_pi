defmodule OctoPi.AI.Event.TextStart do
  @moduledoc "A text content block has begun."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :partial]
end
