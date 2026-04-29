defmodule OctoPi.Coder.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    OctoPi.Tracer.register(%{
      id: :coder_extension,
      description: "Coder extension load, dispatch, per-handler timing, and error events",
      events: %{
        info: [
          [:octo_pi_coder, :extension, :loaded],
          [:octo_pi_coder, :extension, :handler_cancel],
          [:octo_pi_coder, :extension, :handler_override]
        ],
        warning: [
          [:octo_pi_coder, :extension, :load_error],
          [:octo_pi_coder, :extension, :handler_error]
        ],
        debug: [
          [:octo_pi_coder, :extension, :load_start],
          [:octo_pi_coder, :extension, :emit],
          [:octo_pi_coder, :extension, :handler, :start],
          [:octo_pi_coder, :extension, :handler, :stop]
        ]
      }
    })

    OctoPi.Tracer.register(%{
      id: :coder_loop,
      description: "Coder loop lifecycle: init, compaction, navigation, fork, pre-prompt threshold checks",
      events: %{
        info: [
          [:octo_pi_coder, :loop, :init],
          [:octo_pi_coder, :compact, :start],
          [:octo_pi_coder, :compact, :stop],
          [:octo_pi_coder, :navigate, :start],
          [:octo_pi_coder, :navigate, :stop],
          [:octo_pi_coder, :fork, :stop]
        ],
        debug: [
          [:octo_pi_coder, :pre_prompt_check]
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
