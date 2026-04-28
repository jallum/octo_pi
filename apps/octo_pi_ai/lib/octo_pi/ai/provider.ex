defmodule OctoPi.AI.Provider do
  @moduledoc """
  Behaviour every AI provider must implement.

  `stream_to/5` is the push primitive: it spawns a producer task that
  sends `{ref, :event, event}` messages to `pid` and finishes with
  `{ref, :done}`. Returns `{:ok, producer_pid}`.

  See `docs/port-map/anthropic.md` for the reference implementation
  shape.
  """

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Context
  alias OctoPi.AI.Event
  alias OctoPi.AI.Model

  @type event_stream :: Enumerable.t(Event.t())

  @doc """
  Spawn a producer task that pushes `{ref, :event, event}` messages to
  `pid` and sends `{ref, :done}` when the stream ends. Returns
  `{:ok, producer_pid}`.
  """
  @callback stream_to(Model.t(), Context.t(), CallOptions.t(), pid(), reference()) :: {:ok, pid()}
end
