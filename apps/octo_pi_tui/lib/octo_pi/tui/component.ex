defmodule OctoPi.TUI.Component do
  @moduledoc """
  Contract for a TUI component. Components are immutable structs
  that implement this behaviour. `render/2` is required; it takes
  the component state and a width and returns a list of lines
  (binaries, possibly with ANSI escape codes) ready for the
  renderer.

  `handle_key/2` is optional — static components (like `Text`)
  don't need it. For interactive components (`Input`,
  `SelectList`), it takes a `%Key{}` event and returns either an
  updated state, or `{state, [events]}` if the key generated
  higher-level events (e.g. `:submit`, `:select`).
  """

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM

  @type t :: struct()

  @type frame_ms :: non_neg_integer() | nil

  @callback invalidate(t()) :: t()
  @callback update(t(), term()) :: t()
  @callback finalize(t(), term()) :: t()

  @callback render(t(), ctx :: RenderContext.t()) :: {t(), VDOM.t(), frame_ms()}

  @callback handle_key(t(), key :: Key.t()) :: t() | {t(), [term()]}

  @optional_callbacks handle_key: 2, invalidate: 1, update: 2, finalize: 2
end
