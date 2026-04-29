defmodule OctoPi.Coder.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :coder_extension,
      description: "Coder extension load, dispatch, and error events",
      events: %{
        info: [
          [:octo_pi_coder, :extension, :loaded],
          [:octo_pi_coder, :extension, :handler_cancel]
        ],
        warning: [
          [:octo_pi_coder, :extension, :load_error],
          [:octo_pi_coder, :extension, :handler_error]
        ],
        debug: [
          [:octo_pi_coder, :extension, :emit]
        ]
      }
    })

    OctoPi.Tracer.register(%{
      id: :coder_loop,
      description: "Coder loop init events (agent wiring, threshold plumbing)",
      events: %{
        info: [
          [:octo_pi_coder, :loop, :init]
        ]
      }
    })

    children = [
      {Registry, keys: :unique, name: OctoPi.Coder.FileMutex.Registry},
      {DynamicSupervisor, name: OctoPi.Coder.FileMutex.Supervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: OctoPi.Coder.SessionStore.Supervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: OctoPi.Coder.Loop.Supervisor, strategy: :one_for_one}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: OctoPi.Coder.Supervisor)
  end
end
