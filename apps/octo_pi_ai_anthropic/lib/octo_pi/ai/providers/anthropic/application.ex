defmodule OctoPi.AI.Providers.Anthropic.Application do
  @moduledoc false

  use Application

  alias OctoPi.AI.ProviderRegistry
  alias OctoPi.Telemetry.AnthropicHandler

  @impl true
  def start(_type, _args) do
    ProviderRegistry.register(:anthropic_messages, OctoPi.AI.Providers.Anthropic)
    AnthropicHandler.attach()

    children = [
      {Task.Supervisor, name: OctoPi.AI.Providers.Anthropic.TaskSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
