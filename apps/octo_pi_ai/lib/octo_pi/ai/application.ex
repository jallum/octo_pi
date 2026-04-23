defmodule OctoPi.AI.Application do
  @moduledoc false

  use Application

  alias OctoPi.Telemetry.CoreHandler

  @impl true
  def start(_type, _args) do
    CoreHandler.attach()

    children = [
      OctoPi.AI.ProviderRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.AI.Supervisor)
  end
end
