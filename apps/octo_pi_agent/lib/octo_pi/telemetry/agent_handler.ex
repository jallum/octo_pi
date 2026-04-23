defmodule OctoPi.Telemetry.AgentHandler do
  @moduledoc false

  alias OctoPi.Telemetry.Logger, as: TelemetryLogger

  @events [
    [:octo_pi_agent, :session, :start],
    [:octo_pi_agent, :session, :stop],
    [:octo_pi_agent, :turn, :start],
    [:octo_pi_agent, :turn, :stop],
    [:octo_pi_agent, :turn, :exception],
    [:octo_pi_agent, :tool, :start],
    [:octo_pi_agent, :tool, :stop],
    [:octo_pi_agent, :tool, :error]
  ]

  def attach, do: TelemetryLogger.attach("octo-pi-agent-handler", @events)
end
