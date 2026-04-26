defmodule OctoPi.TUI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # No app-level children — Terminal owns its own subscriber list,
    # and is started under Interactive's supervisor when interactive
    # mode kicks in.
    Supervisor.start_link([], strategy: :one_for_one, name: OctoPi.TUI.Supervisor)
  end
end
