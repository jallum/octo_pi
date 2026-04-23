defmodule OctoPi.AI.SSE.Event do
  @moduledoc """
  A raw server-sent event as emitted by `OctoPi.AI.SSE.decode/2`.

  This is the transport-layer event (event name + data payload),
  distinct from `OctoPi.AI.Event` — the canonical AI event union
  that provider decoders build by interpreting these SSE frames.

  `event` is `nil` when the server did not send an `event:` field
  (pi-mono semantics — the WHATWG spec would default to `"message"`,
  but we match pi-mono).
  """

  @type t :: %__MODULE__{
          event: String.t() | nil,
          data: String.t()
        }

  defstruct [:event, :data]
end
