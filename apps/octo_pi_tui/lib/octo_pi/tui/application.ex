defmodule OctoPi.TUI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :tui_events,
      description: "TUI stdin byte, ANSI sequence, and key events",
      events: [
        [:octo_pi_tui, :stdin, :chunk],
        [:octo_pi_tui, :stdin, :sequence],
        [:octo_pi_tui, :key, :event]
      ],
      level: :debug
    })

    OctoPi.Tracer.register(%{
      id: :tui_raw,
      description: "TTY pipeline trace: reader, terminal writes, raw_mode (high-frequency — expect volume)",
      events: [
        [:octo_pi_tui, :reader, :read],
        [:octo_pi_tui, :terminal, :reader_exit],
        [:octo_pi_tui, :terminal, :reader_down],
        [:octo_pi_tui, :terminal, :tty_write],
        [:octo_pi_tui, :terminal, :terminate, :start],
        [:octo_pi_tui, :terminal, :terminate, :stop],
        [:octo_pi_tui, :terminal, :drain, :round],
        [:octo_pi_tui, :raw_mode, :enter, :start],
        [:octo_pi_tui, :raw_mode, :enter, :stop],
        [:octo_pi_tui, :raw_mode, :exit, :start],
        [:octo_pi_tui, :raw_mode, :exit, :phase],
        [:octo_pi_tui, :raw_mode, :exit, :stop]
      ],
      level: :debug
    })

    OctoPi.Tracer.register(%{
      id: :tui_render,
      description: "TUI renderer frame timing + transcript/markdown render spans",
      events: [
        [:octo_pi_tui, :renderer, :render],
        [:octo_pi_tui, :transcript, :render, :start],
        [:octo_pi_tui, :transcript, :render, :stop],
        [:octo_pi_tui, :markdown, :render, :start],
        [:octo_pi_tui, :markdown, :render, :stop]
      ],
      level: :debug
    })

    OctoPi.Tracer.register(%{
      id: :tui_interactive,
      description: "TUI Interactive handle_info spans, mailbox depth, key arrival latency",
      events: [
        [:octo_pi_tui, :interactive, :handle_info, :start],
        [:octo_pi_tui, :interactive, :handle_info, :stop],
        [:octo_pi_tui, :interactive, :mailbox],
        [:octo_pi_tui, :key, :latency]
      ],
      level: :debug
    })

    Supervisor.start_link([], strategy: :one_for_one, name: OctoPi.TUI.Supervisor)
  end
end
