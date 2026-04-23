defmodule OctoPi.AI.Event.Done do
  @moduledoc """
  Terminal event for a successful stream. `message` is the finalized
  assistant message; `reason` is the successful stop reason.
  """

  alias OctoPi.AI.Message.Assistant

  @type reason :: :stop | :length | :tool_use

  @enforce_keys [:reason, :message]
  @type t :: %__MODULE__{
          reason: reason(),
          message: Assistant.t()
        }

  defstruct [:reason, :message]
end
