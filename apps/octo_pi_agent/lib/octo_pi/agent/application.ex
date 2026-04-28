defmodule OctoPi.Agent.Application do
  @moduledoc false

  use Application

  alias OctoPi.Agent.AbortRef

  @impl true
  def start(_type, _args) do
    :ets.new(AbortRef.table_name(), [:named_table, :public, :set, read_concurrency: true])

    OctoPi.Tracer.register(%{
      id: :agent,
      description: "Agent session, turn, and tool lifecycle events",
      events: [
        [:octo_pi_agent, :session, :start],
        [:octo_pi_agent, :session, :stop],
        [:octo_pi_agent, :turn, :start],
        [:octo_pi_agent, :turn, :stop],
        [:octo_pi_agent, :turn, :exception],
        [:octo_pi_agent, :tool, :start],
        [:octo_pi_agent, :tool, :stop]
      ],
      level: :info
    })

    children = [
      {Task.Supervisor, name: OctoPi.Agent.TurnTaskSupervisor},
      {Task.Supervisor, name: OctoPi.Agent.ToolSupervisor},
      {Registry, keys: :duplicate, name: OctoPi.Agent.Subscribers}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)
  end
end
