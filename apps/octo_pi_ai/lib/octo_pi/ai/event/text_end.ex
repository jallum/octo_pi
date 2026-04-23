defmodule OctoPi.AI.Event.TextEnd do
  @moduledoc "A text content block has finished; `content` is the full accumulated string."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :content, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          content: String.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :content, :partial]
end
