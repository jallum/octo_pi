defmodule OctoPi.TUI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Fan-out registry for TUI-internal events (resize, cooked
      # stdin events, key events). Subscribers register under topic
      # atoms; dispatch is :duplicate so multiple subscribers per
      # topic is supported. The Terminal GenServer is added as a
      # child when interactive mode kicks in, not at app boot —
      # there's no TTY to own when tests run or when the user
      # invoked --print / --mode rpc.
      {Registry, keys: :duplicate, name: OctoPi.TUI.Events}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.TUI.Supervisor)
  end
end
