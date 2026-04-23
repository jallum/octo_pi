defmodule OctoPi.Telemetry.CoreHandler do
  @moduledoc false

  require Logger

  @events [
    [:octo_pi_ai, :stream, :open]
  ]

  def attach do
    :telemetry.attach_many("octo-pi-ai-core-handler", @events, &__MODULE__.handle_event/4, nil)
  end

  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")
    Logger.info("[telemetry] #{name} #{inspect(Map.merge(measurements, metadata))}")
  end
end
