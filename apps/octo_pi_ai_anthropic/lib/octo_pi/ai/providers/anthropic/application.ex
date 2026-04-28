defmodule OctoPi.AI.Providers.Anthropic.Application do
  @moduledoc false

  use Application

  alias OctoPi.AI.ProviderRegistry

  @impl true
  def start(_type, _args) do
    ProviderRegistry.register(:anthropic_messages, OctoPi.AI.Providers.Anthropic)

    OctoPi.Tracer.register(%{
      id: :anthropic,
      description: "Anthropic API request and auth events",
      events: [
        [:octo_pi_ai_anthropic, :request, :start],
        [:octo_pi_ai_anthropic, :request, :stop],
        [:octo_pi_ai_anthropic, :request, :exception],
        [:octo_pi_ai_anthropic, :auth, :resolved]
      ],
      level: :info
    })

    children = [
      {Task.Supervisor, name: OctoPi.AI.Providers.Anthropic.TaskSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
