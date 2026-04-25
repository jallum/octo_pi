defmodule OctoPi.TUI.EventLogger do
  @moduledoc false

  # Telemetry handler that logs key-pipeline events to a file.
  # Attach once at TUI startup (when --debug-events is passed); detach
  # on exit.  The log goes to <cwd>/debug_events.log so it survives
  # after the TUI clears the screen.

  @handler_id "octo_pi_tui_event_logger"

  @events [
    [:octo_pi_tui, :stdin, :chunk],
    [:octo_pi_tui, :stdin, :sequence],
    [:octo_pi_tui, :key, :event]
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

  defp handle_event([:octo_pi_tui, :stdin, :chunk], %{byte_count: n}, %{bytes: bytes}, fd) do
    hex = Base.encode16(bytes, case: :lower)
    IO.write(fd, "[chunk] #{n}B hex=#{hex}\n")
  end

  defp handle_event([:octo_pi_tui, :stdin, :sequence], _m, %{seq: seq}, fd) do
    hex = Base.encode16(seq, case: :lower)
    IO.write(fd, "[seq] #{inspect(seq)} hex=#{hex}\n")
  end

  defp handle_event([:octo_pi_tui, :key, :event], _m, %{parsed: parsed}, fd) do
    IO.write(fd, "[key] #{inspect(parsed)}\n")
  end
end
