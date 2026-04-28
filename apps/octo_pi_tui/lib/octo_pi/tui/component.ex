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

  @callback render(state :: struct(), width :: pos_integer()) :: [binary()]

  @callback handle_key(state :: struct(), key :: Key.t()) ::
              struct() | {struct(), [term()]}

  @callback invalidate(state :: struct()) :: struct()

  @optional_callbacks handle_key: 2, invalidate: 1
end
