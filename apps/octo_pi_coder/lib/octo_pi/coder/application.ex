defmodule OctoPi.Coder.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      # Lookup registry for per-path file-mutex workers. Entries are
      # added/removed lazily by `OctoPi.Coder.FileMutex`.
      {Registry, keys: :unique, name: OctoPi.Coder.FileMutex.Registry},
      # DynamicSupervisor hosting the per-path lock GenServers.
      {DynamicSupervisor, name: OctoPi.Coder.FileMutex.Supervisor, strategy: :one_for_one},
      # DynamicSupervisor hosting per-session-id SessionStore GenServers.
      {DynamicSupervisor, name: OctoPi.Coder.SessionStore.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.Coder.Supervisor)
  end
end
