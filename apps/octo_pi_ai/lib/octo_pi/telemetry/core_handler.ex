defmodule OctoPi.Telemetry.CoreHandler do
  @moduledoc false

  alias OctoPi.Telemetry.Logger, as: TelemetryLogger

  @events [
    [:octo_pi_ai, :stream, :open]
  ]

  def attach, do: TelemetryLogger.attach("octo-pi-ai-core-handler", @events)
end
