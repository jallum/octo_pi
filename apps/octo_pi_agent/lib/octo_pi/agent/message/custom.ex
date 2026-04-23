defmodule OctoPi.Agent.Message.Custom do
  @moduledoc """
  App-defined message that appears in the transcript + event stream
  but is stripped before the LLM call. Useful for fork markers,
  session notes, or any side-channel annotation the model should
  not see.

  `payload` is opaque to the agent; consumers interpret by `kind`.
  `timestamp` is Unix milliseconds, consistent with other message
  structs.
  """

  @enforce_keys [:kind, :timestamp]
  @type t :: %__MODULE__{
          kind: atom(),
          payload: term(),
          timestamp: integer()
        }

  defstruct [:kind, :payload, :timestamp]
end
