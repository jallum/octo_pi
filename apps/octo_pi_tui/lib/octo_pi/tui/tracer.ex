defmodule OctoPi.TUI.Tracer do
  @moduledoc false

  # Telemetry handler that writes a timestamped, hex-dumped trace of
  # the stdin/tty/raw-mode pipeline to a file. Activated via the
  # `--trace=PATH` CLI switch (threaded through Interactive.run/1's
  # `:trace` opt). Used to diagnose shutdown-time TTY leaks.

  @handler_id "octo_pi_tui_tracer"

  @events [
    [:octo_pi_tui, :reader, :read],
    [:octo_pi_tui, :stdin, :chunk],
    [:octo_pi_tui, :stdin, :sequence],
    [:octo_pi_tui, :key, :event],
    [:octo_pi_tui, :terminal, :reader_exit],
    [:octo_pi_tui, :terminal, :tty_write],
    [:octo_pi_tui, :terminal, :stdin_eof],
    [:octo_pi_tui, :terminal, :terminate, :start],
    [:octo_pi_tui, :terminal, :terminate, :stop],
    [:octo_pi_tui, :terminal, :drain, :round],
    [:octo_pi_tui, :raw_mode, :enter, :start],
    [:octo_pi_tui, :raw_mode, :enter, :stop],
    [:octo_pi_tui, :raw_mode, :exit, :start],
    [:octo_pi_tui, :raw_mode, :exit, :phase],
    [:octo_pi_tui, :raw_mode, :exit, :stop]
  ]

  @doc "Open the trace file, attach the handler, return the fd."
  @spec attach(Path.t()) :: File.io_device()
  def attach(path) do
    {:ok, fd} = File.open(path, [:write])
    t0 = System.monotonic_time(:microsecond)
    config = %{fd: fd, t0: t0}
    :ok = :telemetry.attach_many(@handler_id, @events, &handle_event/4, config)
    IO.write(fd, "# trace started t0_mono_us=#{t0}\n")
    fd
  end

  @doc "Detach the handler and close the trace file."
  @spec detach(File.io_device()) :: :ok
  def detach(fd) do
    :telemetry.detach(@handler_id)
    File.close(fd)
  end

  defp handle_event(event, measurements, metadata, %{fd: fd, t0: t0}) do
    ts = System.monotonic_time(:microsecond) - t0
    IO.write(fd, "#{pad(ts)} #{format(event, measurements, metadata)}\n")
  end

  defp pad(us), do: String.pad_leading(Integer.to_string(us), 10, " ")

  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp format([:octo_pi_tui, :reader, :read], %{byte_count: n}, %{bytes: b}),
    do: "reader.read #{n}B hex=#{hex(b)} #{inspect(b)}"

  defp format([:octo_pi_tui, :stdin, :chunk], %{byte_count: n}, %{bytes: b}),
    do: "stdin.chunk #{n}B hex=#{hex(b)}"

  defp format([:octo_pi_tui, :stdin, :sequence], _, %{seq: s}),
    do: "stdin.sequence hex=#{hex(s)} #{inspect(s)}"

  defp format([:octo_pi_tui, :key, :event], _, %{parsed: p}),
    do: "key.event #{inspect(p)}"

  defp format([:octo_pi_tui, :terminal, :reader_exit], _, %{reason: r}),
    do: "terminal.reader_exit #{inspect(r)}"

  defp format([:octo_pi_tui, :terminal, :tty_write], %{byte_count: n}, %{bytes: b}),
    do: "terminal.tty_write #{n}B hex=#{hex(b)} #{inspect(b)}"

  defp format([:octo_pi_tui, :terminal, :stdin_eof], _, _),
    do: "terminal.stdin_eof"

  defp format([:octo_pi_tui, :terminal, :terminate, :start], _, meta),
    do: "terminal.terminate.start #{inspect(meta)}"

  defp format([:octo_pi_tui, :terminal, :terminate, :stop], _, _),
    do: "terminal.terminate.stop"

  defp format([:octo_pi_tui, :terminal, :drain, :round], m, %{outcome: o}),
    do: "terminal.drain.round outcome=#{o} #{inspect(m)}"

  defp format([:octo_pi_tui, :raw_mode, :enter, :start], _, _),
    do: "raw_mode.enter.start"

  defp format([:octo_pi_tui, :raw_mode, :enter, :stop], _, meta),
    do: "raw_mode.enter.stop #{inspect(meta)}"

  defp format([:octo_pi_tui, :raw_mode, :exit, :start], _, _),
    do: "raw_mode.exit.start"

  defp format([:octo_pi_tui, :raw_mode, :exit, :phase], _, meta),
    do: "raw_mode.exit.phase #{inspect(meta)}"

  defp format([:octo_pi_tui, :raw_mode, :exit, :stop], _, _),
    do: "raw_mode.exit.stop"
end
