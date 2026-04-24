defmodule OctoPi.Coder.Extension.TelemetryHandler do
  @moduledoc false

  require Logger

  @events [
    [:octo_pi_coder, :extension, :loaded],
    [:octo_pi_coder, :extension, :load_error],
    [:octo_pi_coder, :extension, :emit],
    [:octo_pi_coder, :extension, :handler_error],
    [:octo_pi_coder, :extension, :handler_cancel]
  ]

  @spec attach() :: :ok
  def attach do
    :telemetry.attach_many(
      "octo-pi-coder-extension-logger",
      @events,
      &__MODULE__.handle_event/4,
      nil
    )
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach, do: :telemetry.detach("octo-pi-coder-extension-logger")

  def handle_event([:octo_pi_coder, :extension, :loaded], %{count: 1}, meta, _config) do
    Logger.info("Extension #{meta.id} loaded (#{meta.handler_count} handlers, #{meta.tool_count} tools)")
  end

  def handle_event([:octo_pi_coder, :extension, :load_error], _measurements, meta, _config) do
    Logger.warning("Failed to load extension at #{meta.path}: #{inspect(meta.error)}")
  end

  def handle_event([:octo_pi_coder, :extension, :emit], %{duration: duration}, meta, _config) do
    us = System.convert_time_unit(duration, :native, :microsecond)
    Logger.debug("Dispatched #{meta.event_type} (#{meta.pattern}, #{meta.handler_count} handlers, #{us}µs)")
  end

  def handle_event([:octo_pi_coder, :extension, :handler_error], _measurements, meta, _config) do
    Logger.warning("Extension #{meta.extension_id} error on #{meta.event_type}: #{meta.error}")
  end

  def handle_event([:octo_pi_coder, :extension, :handler_cancel], _measurements, meta, _config) do
    Logger.info("Extension #{meta.extension_id} cancelled #{meta.event_type}: #{inspect(meta.reason)}")
  end
end
