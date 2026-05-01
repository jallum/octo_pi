defmodule OctoPi.AI.Api do
  @moduledoc """
  Behaviour every wire-codec ("API") implementation must satisfy.

  An *API module* speaks one provider protocol — `:anthropic_messages`,
  `:openai_completions`, `:openai_responses`, etc. — and is selected by
  `model.api`. API modules are stateless and know nothing about
  auth.json or model catalogs; those concerns belong to runners
  (`OctoPi.AI.Runner`).

  ## Contract

  `stream_to/4` is the push primitive: it spawns a producer task that
  sends `{producer_pid, :event, event}` messages to `pid` and finishes
  with `{producer_pid, :done}`. Returns `{:ok, producer_pid}`. The push
  shape is deliberate — it composes with OTP processes, monitors, and
  cancellation instead of fighting the actor model with a synchronous
  `Enumerable` shape.

  See `docs/port-map/anthropic.md` for the reference implementation.
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
