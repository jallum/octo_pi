defmodule OctoPi.AI.Provider do
  @moduledoc """
  Behaviour every AI provider must implement.

  `stream/3` and `stream_simple/3` both return an `Enumerable` that
  yields `OctoPi.AI.Event.t()` values. The stream always terminates
  with exactly one of `Event.Done` or `Event.Error` — provider
  failures surface as error events, never as raised exceptions.

  `stream_simple/3` is the user-facing variant that accepts a
  `:reasoning` thinking level and translates it per-provider into the
  right body shape; `stream/3` expects a fully-resolved options map.
  If a provider doesn't yet implement a distinct simple shape it can
  omit the callback and the default dispatcher falls through to
  `stream/3` — see `@optional_callbacks`.

  See `docs/port-map/anthropic.md` for the reference implementation
  shape.
  """

  alias OctoPi.AI.{Context, Event, Model, StreamOptions}

  @type event_stream :: Enumerable.t(Event.t())

  @doc """
  Open a provider stream with a fully-resolved options struct.
  Must return an `Enumerable` yielding `Event.t()`.
  """
  @callback stream(Model.t(), Context.t(), StreamOptions.t()) :: event_stream()

  @doc """
  Open a provider stream with the higher-level options that include
  `:reasoning` and `:thinking_budgets`. The provider translates those
  into whatever concrete shape it needs.
  """
  @callback stream_simple(Model.t(), Context.t(), StreamOptions.t()) :: event_stream()

  @optional_callbacks [stream_simple: 3]
end
