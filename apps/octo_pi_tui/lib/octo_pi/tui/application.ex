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
      id: :tui_agent,
      description: "Agent session, turn, and tool lifecycle events (TUI view)",
      events: [
        [:octo_pi_agent, :session, :start],
        [:octo_pi_agent, :session, :stop],
        [:octo_pi_agent, :turn, :start],
        [:octo_pi_agent, :turn, :stop],
        [:octo_pi_agent, :tool, :start],
        [:octo_pi_agent, :tool, :stop],
        [:octo_pi_agent, :tool, :error]
      ],
      level: :info
    })

    OctoPi.Tracer.register(%{
      id: :tui_raw,
      description: "TTY pipeline trace: reader, stdin, key, terminal, raw_mode (high-frequency — expect volume)",
      events: [
        [:octo_pi_tui, :reader, :read],
        [:octo_pi_tui, :stdin, :chunk],
        [:octo_pi_tui, :stdin, :sequence],
        [:octo_pi_tui, :key, :event],
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
      description: "TUI renderer frame timing and throttle skips",
      events: [
        [:octo_pi_tui, :renderer, :render],
        [:octo_pi_tui, :render_throttle, :skip]
      ],
      level: :debug
    })

    Supervisor.start_link([], strategy: :one_for_one, name: OctoPi.TUI.Supervisor)
  end
end
