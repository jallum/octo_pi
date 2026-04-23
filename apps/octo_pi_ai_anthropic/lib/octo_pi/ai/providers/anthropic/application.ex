defmodule OctoPi.AI.Providers.Anthropic.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    register_provider()
    Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
  end

  # Register this provider in the core `octo_pi_ai` app's registry so
  # `OctoPi.AI.stream/3` can dispatch to us without a hard dependency
  # at the module level. Idempotent: merges into whatever's there.
  defp register_provider do
    current = Application.get_env(:octo_pi_ai, :providers, %{})
    merged = Map.put(current, :anthropic_messages, OctoPi.AI.Providers.Anthropic)
    Application.put_env(:octo_pi_ai, :providers, merged)
  end
end
