defmodule OctoPi.Agent.Application do
  @moduledoc false

  use Application

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Telemetry.AgentHandler

  @impl true
  def start(_type, _args) do
    :ets.new(AbortRef.table_name(), [:named_table, :public, :set, read_concurrency: true])

    AgentHandler.attach()

    children = [
      {Task.Supervisor, name: OctoPi.Agent.TurnTaskSupervisor},
      {Task.Supervisor, name: OctoPi.Agent.ToolSupervisor},
      {Registry, keys: :duplicate, name: OctoPi.Agent.Subscribers}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
