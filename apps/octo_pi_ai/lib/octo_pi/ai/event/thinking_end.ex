defmodule OctoPi.AI.Event.ThinkingEnd do
  @moduledoc "A thinking content block has finished."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :content, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          content: String.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :content, :partial]
end
