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

  The bridge is opt-in and defaults to off so tests and production
  stay quiet. Enable it in config with:

      config :octo_pi_ai, OctoPi.Telemetry.Logger, enabled: true
  """

  require Logger

  @doc """
  Attach a Logger-backed handler to a list of telemetry events.
  `handler_id` should be unique across the VM (conventional shape:
  `"<app-name>-<purpose>"`).

  No-op unless the bridge is enabled (see module doc).
  """
  @spec attach(String.t(), [:telemetry.event_name()]) :: :ok | {:error, :already_exists}
  def attach(handler_id, events) when is_binary(handler_id) and is_list(events) do
    if enabled?() do
      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, nil)
    else
      :ok
    end
  end

  defp enabled? do
    Application.get_env(:octo_pi_ai, __MODULE__, [])
    |> Keyword.get(:enabled, false)
  end

  @doc false
  def handle_event(event, measurements, metadata, _config) do
    name = Enum.join(event, ".")
    Logger.info("[telemetry] #{name} #{inspect(Map.merge(measurements, metadata))}")
  end
end
