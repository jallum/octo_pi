defmodule OctoPi.AI.Providers.OpenAI.Application do
  @moduledoc false

  use Application

  alias OctoPi.AI.ProviderRegistry

  @impl true
  def start(_type, _args) do
    ProviderRegistry.register(:openai_completions, OctoPi.AI.Providers.OpenAI)

    children = [
      {Task.Supervisor, name: OctoPi.AI.Providers.OpenAI.TaskSup}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
