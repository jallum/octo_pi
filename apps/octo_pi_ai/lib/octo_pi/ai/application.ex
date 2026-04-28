defmodule OctoPi.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :ai_core,
      description: "AI core events (stream opens)",
      events: [[:octo_pi_ai, :stream, :open]],
      level: :info
    })

    children = [
      OctoPi.AI.ProviderRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.AI.Supervisor)
  end
end
