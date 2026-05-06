defmodule OctoPi.AI.Providers.OpenRouter.Application do
  @moduledoc false

  use Application

  alias OctoPi.AI.RunnerRegistry

  @impl true
  def start(_type, _args) do
    RunnerRegistry.register(:openrouter, OctoPi.AI.Runners.OpenRouter)

    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end
end
