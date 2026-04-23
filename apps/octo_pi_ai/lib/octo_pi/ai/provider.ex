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

  See `docs/port-map/anthropic.md` for the reference implementation
  shape.
  """

  alias OctoPi.AI.{Context, Model, StreamOptions}

  @doc """
  Open a provider stream with a fully-resolved options struct.
  Must return an `Enumerable` yielding `Event.t()`.
  """
  @callback stream(Model.t(), Context.t(), StreamOptions.t()) :: Enumerable.t()

  @doc """
  Open a provider stream with the higher-level options that include
  `:reasoning` and `:thinking_budgets`. The provider translates those
  into whatever concrete shape it needs.
  """
  @callback stream_simple(Model.t(), Context.t(), StreamOptions.t()) :: Enumerable.t()
end
