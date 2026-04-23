defmodule OctoPi.AI.Application do
  @moduledoc false

  use Application

  alias OctoPi.Telemetry.CoreHandler

  @impl true
  def start(_type, _args) do
    CoreHandler.attach()
    Supervisor.start_link([], strategy: :one_for_one, name: OctoPi.AI.Supervisor)
  end
end
