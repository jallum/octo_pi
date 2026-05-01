defmodule OctoPi.AI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :ai_core,
      description: "AI provider request lifecycle events (all providers)",
      events: [
        [:octo_pi_ai, :request, :start],
        [:octo_pi_ai, :request, :stop],
        [:octo_pi_ai, :request, :exception]
      ],
      level: :info
    })

    children = [
      OctoPi.AI.ApiRegistry,
      OctoPi.AI.RunnerRegistry
    ]

    OctoPi.AI.Tracing.maybe_attach()

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.AI.Supervisor)
  end
end
