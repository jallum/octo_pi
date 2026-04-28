defmodule OctoPi.Telemetry.OpenAIHandler do
  @moduledoc false

  alias OctoPi.Telemetry.Logger, as: TelemetryLogger

  @events [
    [:octo_pi_ai_openai, :request, :start],
    [:octo_pi_ai_openai, :request, :stop],
    [:octo_pi_ai_openai, :request, :exception]
  ]

  def attach, do: TelemetryLogger.attach("octo-pi-ai-openai-handler", @events)
end
