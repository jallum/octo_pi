defmodule OctoPi.AI.Provider do
  @moduledoc """
  Behaviour every AI provider must implement.

  `stream_to/4` is the push primitive: it spawns a producer task that
  sends `{producer_pid, :event, event}` messages to `pid` and finishes
  with `{producer_pid, :done}`. Returns `{:ok, producer_pid}`.

  See `docs/port-map/anthropic.md` for the reference implementation
  shape.
  """

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Context
  alias OctoPi.AI.Event
  alias OctoPi.AI.Model

  @type event_stream :: Enumerable.t(Event.t())

  @doc """
  Spawn a producer task that pushes `{producer_pid, :event, event}`
  messages to `pid` and sends `{producer_pid, :done}` when the stream
  ends. Returns `{:ok, producer_pid}`.
  """
  @callback stream_to(Model.t(), Context.t(), CallOptions.t(), pid()) :: {:ok, pid()}
end
