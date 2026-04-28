defmodule OctoPi.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :ai_core,
      description: "AI core stream lifecycle events (open and close)",
      events: [[:octo_pi_ai, :stream, :open], [:octo_pi_ai, :stream, :close]],
      level: :info
    })

    children = [
      OctoPi.AI.ProviderRegistry
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.AI.Supervisor)
  end
end
