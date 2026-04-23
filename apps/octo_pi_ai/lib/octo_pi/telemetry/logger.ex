defmodule OctoPi.Telemetry.Logger do
  @moduledoc """
  Shared telemetry-to-Logger bridge.

  Per-app handlers (`OctoPi.Telemetry.CoreHandler`,
  `OctoPi.Telemetry.AnthropicHandler`, …) call `attach/2` with a
  unique handler id and the list of event names they care about.
  Every event fires a single `Logger.info/1` line in the octopus
  format: `[telemetry] name key: value, ...`.

  Kept in the core (`octo_pi_ai`) so sibling provider apps can depend
  on it without reaching into each other.
  """

  require Logger

  @doc """
  Attach a Logger-backed handler to a list of telemetry events.
  `handler_id` should be unique across the VM (conventional shape:
  `"<app-name>-<purpose>"`).
  """
  @spec attach(String.t(), [:telemetry.event_name()]) :: :ok | {:error, :already_exists}
  def attach(handler_id, events) when is_binary(handler_id) and is_list(events) do
    :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, nil)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")
    Logger.info("[telemetry] #{name} #{inspect(Map.merge(measurements, metadata))}")
  end
end
