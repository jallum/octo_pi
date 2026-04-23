defmodule OctoPi.AI.Event.ThinkingDelta do
  @moduledoc "An incremental chunk of a thinking content block."

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :delta, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          delta: String.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :delta, :partial]
end
