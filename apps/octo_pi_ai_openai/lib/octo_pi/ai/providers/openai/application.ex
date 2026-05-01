defmodule OctoPi.AI.Providers.OpenAI.Application do
  @moduledoc false

  use Application

  alias OctoPi.AI.ApiRegistry
  alias OctoPi.AI.RunnerRegistry

  @impl true
  def start(_type, _args) do
    ApiRegistry.register(:openai_completions, OctoPi.AI.Providers.OpenAI)
    RunnerRegistry.register(:lmstudio, OctoPi.AI.Runners.LMStudio)

    children = [
      {Task.Supervisor, name: OctoPi.AI.Providers.OpenAI.TaskSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
