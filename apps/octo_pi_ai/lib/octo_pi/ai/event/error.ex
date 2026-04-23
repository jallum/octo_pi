defmodule OctoPi.AI.Event.Error do
  @moduledoc """
  Terminal event for a failed or cancelled stream. `message` carries
  the partial assistant message; `message.error_message` holds the
  human-readable cause.
  """

  alias OctoPi.AI.Message.Assistant

  @type reason :: :error | :aborted

  @enforce_keys [:reason, :message]
  @type t :: %__MODULE__{
          reason: reason(),
          message: Assistant.t()
        }

  defstruct [:reason, :message]
end
