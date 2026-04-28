defmodule OctoPi.TUI.AgentTelemetryLogger do
  @moduledoc false

  # Telemetry handler that logs agent session/turn/tool lifecycle events
  # to a file. Attach with --telemetry=PATH; detach on exit.

  @handler_id "octo_pi_tui_agent_telemetry_logger"

  @events [
    [:octo_pi_agent, :session, :start],
    [:octo_pi_agent, :session, :stop],
    [:octo_pi_agent, :turn, :start],
    [:octo_pi_agent, :turn, :stop],
    [:octo_pi_agent, :tool, :start],
    [:octo_pi_agent, :tool, :end],
    [:octo_pi_agent, :tool, :error]
  ]

  @doc "Open the log file, attach the telemetry handler, return the fd."
  @spec attach(Path.t()) :: File.io_device()
  def attach(log_path) do
    {:ok, fd} = File.open(log_path, [:write, :utf8])
    :ok = :telemetry.attach_many(@handler_id, @events, &handle_event/4, fd)
    fd
  end

  @doc "Detach the handler and close the log file."
  @spec detach(File.io_device()) :: :ok
  def detach(fd) do
    :telemetry.detach(@handler_id)
    File.close(fd)
  end

  defp handle_event([:octo_pi_agent, :session, :start], %{system_time: ts}, %{model: model}, fd) do
    IO.write(fd, "[#{fmt(ts)}] session.start model=#{model}\n")
  end

  defp handle_event([:octo_pi_agent, :session, :stop], %{duration: dur}, meta, fd) do
    ms = System.convert_time_unit(dur, :native, :millisecond)
    IO.write(fd, "[session.stop] duration=#{ms}ms reason=#{inspect(meta[:reason])} turns=#{meta[:turn_count]}\n")
  end

  defp handle_event([:octo_pi_agent, :turn, :start], %{system_time: ts}, %{turn: turn}, fd) do
    IO.write(fd, "[#{fmt(ts)}] turn.start turn=#{inspect(turn)}\n")
  end

  defp handle_event([:octo_pi_agent, :turn, :stop], %{duration: dur}, meta, fd) do
    ms = System.convert_time_unit(dur, :native, :millisecond)
    IO.write(fd, "[turn.stop] duration=#{ms}ms turn=#{inspect(meta[:turn])} reason=#{inspect(meta[:stop_reason])}\n")
  end

  defp handle_event([:octo_pi_agent, :tool, :start], %{system_time: ts}, meta, fd) do
    IO.write(fd, "[#{fmt(ts)}] tool.start name=#{meta[:tool_name]} id=#{meta[:tool_call_id]}\n")
  end

  defp handle_event([:octo_pi_agent, :tool, event], %{duration: dur}, meta, fd) do
    ms = System.convert_time_unit(dur, :native, :millisecond)
    IO.write(fd, "[tool.#{event}] duration=#{ms}ms name=#{meta[:tool_name]} id=#{meta[:tool_call_id]} error=#{meta[:is_error?]}\n")
  end

  defp handle_event(event, _measurements, _meta, fd) do
    IO.write(fd, "[unknown] #{inspect(event)}\n")
  end

  defp fmt(system_time) do
    system_time
    |> System.convert_time_unit(:native, :microsecond)
    |> then(&DateTime.from_unix!(&1, :microsecond))
    |> Calendar.strftime("%H:%M:%S.%f")
  end
end
