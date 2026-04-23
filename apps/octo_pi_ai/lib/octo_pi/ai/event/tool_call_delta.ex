defmodule OctoPi.AI.Event.ToolCallDelta do
  @moduledoc """
  An incremental chunk of a tool-call's streaming JSON arguments.
  `delta` is the raw JSON fragment; the caller's `partial` reflects
  the provider's best-effort parse of the accumulated buffer.
  """

  alias OctoPi.AI.Message.Assistant

  @enforce_keys [:content_index, :delta, :partial]
  @type t :: %__MODULE__{
          content_index: non_neg_integer(),
          delta: String.t(),
          partial: Assistant.t()
        }

  defstruct [:content_index, :delta, :partial]
end
