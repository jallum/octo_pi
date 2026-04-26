defmodule OctoPi.TUI do
  @moduledoc """
  Terminal-UI application layer. Wraps the Phase 3 coder's agent
  session with a raw-mode input pipeline (Terminal → KeyParser) and
  a differential renderer that paints assistant turns + a prompt
  editor to the screen.

  Public facade is intentionally thin. Reach for specific
  submodules:

    * `OctoPi.TUI.Terminal` — raw-mode lifecycle, SIGWINCH, and
      stdin escape-sequence assembly (`StdinFSM`)
    * `OctoPi.TUI.KeyParser` — bytes → `%Key{}`
    * `OctoPi.TUI.Renderer` — screen diff + atomic writes
    * `OctoPi.TUI.Interactive` — main loop for `mix pi`

  See `docs/port-map/tui.md` for the full design.
  """
end
