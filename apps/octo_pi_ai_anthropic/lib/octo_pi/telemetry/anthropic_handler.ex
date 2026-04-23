defmodule OctoPi.Telemetry.AnthropicHandler do
  @moduledoc false

  alias OctoPi.Telemetry.Logger, as: TelemetryLogger

  # All Anthropic-provider events live under the owning app's atom so
  # downstream consumers can filter by app prefix cleanly.
  @events [
    [:octo_pi_ai_anthropic, :request, :start],
    [:octo_pi_ai_anthropic, :request, :stop],
    [:octo_pi_ai_anthropic, :request, :exception],
    [:octo_pi_ai_anthropic, :auth, :resolved]
  ]

  def attach, do: TelemetryLogger.attach("octo-pi-ai-anthropic-handler", @events)
end
