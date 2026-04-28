defmodule OctoPi.Tracer.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.init()
    Supervisor.start_link([], strategy: :one_for_one, name: OctoPi.Tracer.Supervisor)
  end
end
