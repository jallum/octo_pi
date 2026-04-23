defmodule OctoPi.Telemetry.AnthropicHandler do
  @moduledoc false

  require Logger

  @events [
    [:octo_pi_ai, :anthropic, :request, :start],
    [:octo_pi_ai, :anthropic, :request, :stop],
    [:octo_pi_ai, :anthropic, :request, :exception],
    [:octo_pi_ai, :anthropic, :auth, :resolved]
  ]

  def attach do
    :telemetry.attach_many(
      "octo-pi-ai-anthropic-handler",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")
    Logger.info("[telemetry] #{name} #{inspect(Map.merge(measurements, metadata))}")
  end
end
