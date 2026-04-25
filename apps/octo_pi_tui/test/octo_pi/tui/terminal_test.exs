defmodule OctoPi.TUI.TerminalTest do
  use ExUnit.Case, async: false

  alias OctoPi.TUI.Events
  alias OctoPi.TUI.Terminal

  def __reader_exit_forward__(_event, _measurements, meta, %{pid: pid}) do
    send(pid, {:reader_exit, meta.reason})
  end

  # All tests use test-friendly opts that skip the real tty plumbing:
  # - skip_raw_mode:  don't call :shell.start_interactive (would break
  #   the test runner's terminal).
  # - skip_sigwinch:  don't register :os.set_signal/2 (would register
  #   globally and clobber other tests).
  # - auto_start_reader: false — don't spawn the reader loop that
  #   blocks on :io.get_chars/2 in production.
  # - dimensions: {cols, rows} — inject initial size.
  defp start_terminal(opts \\ []) do
    defaults = [
      skip_raw_mode: true,
      skip_sigwinch: true,
      auto_start_reader: false,
      dimensions: {80, 24}
    ]

    {:ok, pid} = Terminal.start_link(Keyword.merge(defaults, opts))
    pid
  end

  describe "start_link / dimensions" do
    test "records initial width and height from opts" do
      pid = start_terminal(dimensions: {100, 30})
      assert %{width: 100, height: 30} = Terminal.info(pid)
    end
  end

  describe "feed_chunk/2" do
    test "broadcasts the chunk via Events under {:stdin_chunk, scope} topic" do
      pid = start_terminal()
      {:ok, _} = Registry.register(Events, {:stdin_chunk, pid}, nil)
      :ok = Terminal.feed_chunk(pid, "abc")
      assert_receive {:stdin_chunk, "abc"}, 500
    end

    test "forwards multiple chunks in order" do
      pid = start_terminal()
      {:ok, _} = Registry.register(Events, {:stdin_chunk, pid}, nil)
      :ok = Terminal.feed_chunk(pid, "a")
      :ok = Terminal.feed_chunk(pid, "b")
      assert_receive {:stdin_chunk, "a"}, 500
      assert_receive {:stdin_chunk, "b"}, 500
    end
  end

  describe "SIGWINCH handling" do
    test "simulated sigwinch broadcasts a resize event with new dimensions" do
      pid = start_terminal(dimensions: {80, 24})
      {:ok, _} = Registry.register(Events, {:resize, pid}, nil)

      # Drive the resize with an explicit dims override — in
      # production we'd read :io.columns/0, but tests inject.
      :ok = Terminal.simulate_resize(pid, 120, 40)

      assert_receive {:resize, 120, 40}, 500
      assert %{width: 120, height: 40} = Terminal.info(pid)
    end
  end

  describe "event isolation" do
    test "two terminals only deliver events to their own subscribers" do
      t1 = start_terminal(name: nil)
      t2 = start_terminal(name: nil)

      {:ok, _} = Registry.register(Events, {:stdin_chunk, t1}, nil)

      Terminal.feed_chunk(t1, "from_t1")
      Terminal.feed_chunk(t2, "from_t2")

      assert_receive {:stdin_chunk, "from_t1"}, 500
      refute_receive {:stdin_chunk, "from_t2"}, 100
    end
  end

  describe "keyboard protocol negotiation (opi-0g4.1)" do
    test "sends Kitty probe on init in raw mode" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      assert_receive {:tty, "\e[?u"}, 500
    end

    test "enables Kitty push flags when probe response received" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      assert_receive {:tty, "\e[?u"}, 500
      Terminal.simulate_stdin(pid, "\e[?1u")
      Terminal.info(pid)
      assert_receive {:tty, "\e[>7u"}, 500
      assert Terminal.kitty_protocol_active?(pid)
    end

    test "falls back to modifyOtherKeys when no response within timeout" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      _pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10
        )

      assert_receive {:tty, "\e[?u"}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500
    end

    test "kitty_protocol_active? returns false with modifyOtherKeys fallback" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10
        )

      assert_receive {:tty, "\e[>4;2m"}, 500
      refute Terminal.kitty_protocol_active?(pid)
    end

    test "disables Kitty on terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      assert_receive {:tty, "\e[?u"}, 500
      Terminal.simulate_stdin(pid, "\e[?1u")
      Terminal.info(pid)
      assert_receive {:tty, "\e[>7u"}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:tty, "\e[<0u"}, 500
    end

    test "disables modifyOtherKeys on terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10
        )

      assert_receive {:tty, "\e[>4;2m"}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:tty, "\e[>4m"}, 500
    end

    test "skip_raw_mode suppresses Kitty probe" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      _pid = start_terminal(name: nil, tty_fn: tty_fn)
      refute_receive {:tty, "\e[?u"}, 100
    end

    test "non-Kitty stdin chunk while probing is forwarded normally" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 100
        )

      assert_receive {:tty, "\e[?u"}, 500
      {:ok, _} = Registry.register(Events, {:stdin_chunk, pid}, nil)
      Terminal.simulate_stdin(pid, "a")
      assert_receive {:stdin_chunk, "a"}, 500
    end
  end

  describe "bracketed paste mode (opi-0g4.2)" do
    test "sends enable sequence on init" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      assert_receive {:tty, "\e[?2004h"}, 500
    end

    test "sends disable sequence on terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      assert_receive {:tty, "\e[?2004h"}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:tty, "\e[?2004l"}, 500
    end
  end

  describe "write/2" do
    test "routes bytes to the injected write_fn" do
      test_pid = self()
      write_fn = fn bytes -> send(test_pid, {:written, bytes}) end
      pid = start_terminal(name: nil, write_fn: write_fn)

      Terminal.write(pid, "hello")
      assert_receive {:written, "hello"}, 500
    end
  end

  describe "terminate/2" do
    test "calls raw_mode.exit on normal shutdown" do
      test_pid = self()

      raw_mode = fn action ->
        send(test_pid, {:raw_mode, action})
        :ok
      end

      pid =
        start_terminal(
          skip_raw_mode: false,
          raw_mode_fn: raw_mode,
          tty_fn: fn _ -> :ok end
        )

      assert_receive {:raw_mode, :enter}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:raw_mode, :exit}, 500
    end

    test "calls raw_mode.exit on non-normal shutdown" do
      test_pid = self()
      Process.flag(:trap_exit, true)

      raw_mode = fn action ->
        send(test_pid, {:raw_mode, action})
        :ok
      end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: raw_mode,
          tty_fn: fn _ -> :ok end
        )

      assert_receive {:raw_mode, :enter}, 500
      GenServer.stop(pid, :shutdown)
      assert_receive {:raw_mode, :exit}, 500
    end
  end

  describe "drain input on exit (opi-0g4.3)" do
    test "terminate waits at least drain_idle_ms when no pending chunks" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10,
          drain_idle_ms: 50
        )

      assert_receive {:tty, "\e[?u"}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500

      t0 = System.monotonic_time(:millisecond)
      GenServer.stop(pid, :normal)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 40
      assert elapsed < 400
    end

    test "drain_timeout_ms caps total drain when drain_idle_ms is large" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10,
          drain_idle_ms: 5000,
          drain_timeout_ms: 60
        )

      assert_receive {:tty, "\e[?u"}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500

      t0 = System.monotonic_time(:millisecond)
      GenServer.stop(pid, :normal)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 40
      assert elapsed < 500
    end

    test "skip_raw_mode skips drain entirely" do
      tty_fn = fn _ -> :ok end
      pid = start_terminal(name: nil, tty_fn: tty_fn, drain_idle_ms: 5000)

      t0 = System.monotonic_time(:millisecond)
      GenServer.stop(pid, :normal)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed < 200
    end

    test "drain discards stdin chunks injected into mailbox during terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 10,
          drain_idle_ms: 200
        )

      assert_receive {:tty, "\e[?u"}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500

      {:ok, _} = Registry.register(Events, {:stdin_chunk, pid}, nil)

      stop_task = Task.async(fn -> GenServer.stop(pid, :normal) end)

      # Wait until disable_keyboard_protocol fires — drain starts immediately after
      assert_receive {:tty, "\e[>4m"}, 500
      send(pid, {:stdin_chunk, "key_release"})

      Task.await(stop_task, 2000)

      refute_receive {:stdin_chunk, "key_release"}, 100
    end
  end

  describe "reader exit diagnostics" do
    @describetag capture_log: true

    test "emits telemetry on :eof" do
      test_pid = self()

      :telemetry.attach(
        "test-reader-eof-#{inspect(test_pid)}",
        [:octo_pi_tui, :terminal, :reader_exit],
        &__MODULE__.__reader_exit_forward__/4,
        %{pid: test_pid}
      )

      _pid =
        start_terminal(
          name: nil,
          auto_start_reader: true,
          reader_fn: fn -> :eof end
        )

      assert_receive {:reader_exit, :eof}, 1_000

      :telemetry.detach("test-reader-eof-#{inspect(test_pid)}")
    end

    test "emits telemetry on {:error, reason}" do
      test_pid = self()

      :telemetry.attach(
        "test-reader-err-#{inspect(test_pid)}",
        [:octo_pi_tui, :terminal, :reader_exit],
        &__MODULE__.__reader_exit_forward__/4,
        %{pid: test_pid}
      )

      _pid =
        start_terminal(
          name: nil,
          auto_start_reader: true,
          reader_fn: fn -> {:error, :closed} end
        )

      assert_receive {:reader_exit, {:error, :closed}}, 1_000

      :telemetry.detach("test-reader-err-#{inspect(test_pid)}")
    end
  end
end
