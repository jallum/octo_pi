defmodule OctoPi.TUI.TerminalTest do
  use ExUnit.Case, async: false

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Terminal
  alias OctoPi.TUI.TerminalHelpers

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

  describe "stdin chunk processing" do
    test "broadcasts parsed key events under {:key_event, scope} topic" do
      pid = start_terminal()
      :ok = Terminal.open(pid)
      :ok = TerminalHelpers.simulate_stdin(pid, "abc")
      assert_receive {:key_event, {:key, %Key{key: ?a}}}, 500
      assert_receive {:key_event, {:key, %Key{key: ?b}}}, 500
      assert_receive {:key_event, {:key, %Key{key: ?c}}}, 500
    end

    test "forwards multiple chunks in order" do
      pid = start_terminal()
      :ok = Terminal.open(pid)
      :ok = TerminalHelpers.simulate_stdin(pid, "a")
      :ok = TerminalHelpers.simulate_stdin(pid, "b")
      assert_receive {:key_event, {:key, %Key{key: ?a}}}, 500
      assert_receive {:key_event, {:key, %Key{key: ?b}}}, 500
    end
  end

  describe "SIGWINCH handling" do
    test "simulated sigwinch broadcasts a resize event with new dimensions" do
      pid = start_terminal(dimensions: {80, 24})
      :ok = Terminal.open(pid)

      # Drive the resize with an explicit dims override — in
      # production we'd read :io.columns/0, but tests inject.
      :ok = TerminalHelpers.simulate_resize(pid, 120, 40)

      assert_receive {:resize, 120, 40}, 500
      assert %{width: 120, height: 40} = Terminal.info(pid)
    end
  end

  describe "event isolation" do
    test "two terminals only deliver events to their own subscribers" do
      t1 = start_terminal(name: nil)
      t2 = start_terminal(name: nil)

      :ok = Terminal.open(t1)

      TerminalHelpers.simulate_stdin(t1, "x")
      TerminalHelpers.simulate_stdin(t2, "y")

      assert_receive {:key_event, {:key, %Key{key: ?x}}}, 500
      refute_receive {:key_event, {:key, %Key{key: ?y}}}, 100
    end
  end

  describe "keyboard protocol negotiation (opi-0g4.1)" do
    test "sends Kitty probe on first open in raw mode" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?u"}, 500
    end

    test "enables Kitty push flags when probe response received" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?u"}, 500
      send(Terminal.info(pid).reader_pid, {:tty_chunk, "\e[?1u"})
      assert_receive {:tty, "\e[>7u"}, 500
    end

    test "falls back to modifyOtherKeys when no response within timeout" do
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

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?u"}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500
    end

    test "disables Kitty on terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
      send(Terminal.info(pid).reader_pid, {:tty_chunk, "\e[?1u"})
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

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[>4;2m"}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:tty, "\e[>4m"}, 500
    end

    test "skip_raw_mode suppresses Kitty probe" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
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

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?u"}, 500
      TerminalHelpers.simulate_stdin(pid, "a")
      assert_receive {:key_event, {:key, %Key{key: ?a}}}, 500
    end
  end

  describe "stdin FSM ownership (opi-445.2)" do
    test "bare ESC is held, then flushed as cooked event after flush_ms" do
      pid = start_terminal(flush_ms: 20)
      :ok = Terminal.open(pid)
      TerminalHelpers.simulate_stdin(pid, "\e")
      refute_receive {:key_event, _}, 5
      assert_receive {:key_event, {:key, %Key{key: :escape}}}, 200
    end

    test "flush deadline coexists with probe deadline (multiplexed)" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: fn _ -> :ok end,
          tty_fn: tty_fn,
          probe_timeout_ms: 100,
          flush_ms: 20
        )

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?u"}, 500

      # During probe, send a bare ESC: flush deadline (20ms) is
      # nearer than probe deadline (100ms). The flush should fire
      # first, then the probe should still fall back.
      TerminalHelpers.simulate_stdin(pid, "\e")

      assert_receive {:key_event, {:key, %Key{key: :escape}}}, 200
      assert_receive {:tty, "\e[>4;2m"}, 500
    end
  end

  describe "bracketed paste mode (opi-0g4.2)" do
    test "sends enable sequence on first open" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[?2004h"}, 500
    end

    test "sends disable sequence on terminate" do
      test_pid = self()
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end
      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: fn _ -> :ok end, tty_fn: tty_fn)
      :ok = Terminal.open(pid)
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
      raw_mode = fn action -> send(test_pid, {:raw_mode, action}) && :ok end

      pid = start_terminal(skip_raw_mode: false, raw_mode_fn: raw_mode, tty_fn: fn _ -> :ok end)
      :ok = Terminal.open(pid)
      assert_receive {:raw_mode, :enter}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:raw_mode, :exit}, 500
    end

    test "calls raw_mode.exit on non-normal shutdown" do
      test_pid = self()
      Process.flag(:trap_exit, true)
      raw_mode = fn action -> send(test_pid, {:raw_mode, action}) && :ok end

      pid = start_terminal(name: nil, skip_raw_mode: false, raw_mode_fn: raw_mode, tty_fn: fn _ -> :ok end)
      :ok = Terminal.open(pid)
      assert_receive {:raw_mode, :enter}, 500
      GenServer.stop(pid, :shutdown)
      assert_receive {:raw_mode, :exit}, 500
    end

    test "runs terminate when stopped via supervisor shutdown signal (opi-445.5)" do
      test_pid = self()
      Process.flag(:trap_exit, true)
      raw_mode = fn action -> send(test_pid, {:raw_mode, action}) && :ok end
      tty_fn = fn bytes -> send(test_pid, {:tty, bytes}) end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: raw_mode,
          tty_fn: tty_fn,
          probe_timeout_ms: 10
        )

      :ok = Terminal.open(pid)
      assert_receive {:raw_mode, :enter}, 500
      assert_receive {:tty, "\e[>4;2m"}, 500

      Process.exit(pid, :shutdown)

      # disable_keyboard_protocol must run *before* raw_mode.exit
      assert_receive {:tty, "\e[>4m"}, 500
      assert_receive {:raw_mode, :exit}, 500
    end
  end

  describe "open_editor (opi-0g4.14)" do
    test "open_editor calls raw_mode exit then enter" do
      test_pid = self()
      raw_mode_fn = fn action -> send(test_pid, {:raw_mode, action}) && :ok end

      pid =
        start_terminal(
          name: nil,
          skip_raw_mode: false,
          raw_mode_fn: raw_mode_fn,
          tty_fn: fn _ -> :ok end,
          open_editor_fn: fn _path -> :ok end
        )

      :ok = Terminal.open(pid)
      assert_receive {:raw_mode, :enter}, 500
      Terminal.open_editor(pid, "hello")

      assert_received {:raw_mode, :exit}
      assert_received {:raw_mode, :enter}
    end

    test "open_editor invokes open_editor_fn with a temp file path" do
      test_pid = self()

      open_editor_fn = fn path ->
        send(test_pid, {:editor_path, path})
        :ok
      end

      pid = start_terminal(name: nil, open_editor_fn: open_editor_fn)
      Terminal.open_editor(pid, "initial")

      assert_receive {:editor_path, path}, 500
      assert is_binary(path)
    end

    test "open_editor writes initial text to temp file before calling fn" do
      test_pid = self()

      open_editor_fn = fn path ->
        send(test_pid, {:file_content, File.read!(path)})
        :ok
      end

      pid = start_terminal(name: nil, open_editor_fn: open_editor_fn)
      Terminal.open_editor(pid, "my initial text")

      assert_receive {:file_content, "my initial text"}, 500
    end

    test "open_editor returns {:ok, content} written by fn" do
      open_editor_fn = fn path ->
        File.write!(path, "edited content")
        :ok
      end

      pid = start_terminal(name: nil, open_editor_fn: open_editor_fn)
      assert {:ok, "edited content"} = Terminal.open_editor(pid, "original")
    end

    test "open_editor returns {:error, :no_editor} when fn returns {:error, :no_editor}" do
      pid = start_terminal(name: nil, open_editor_fn: fn _path -> {:error, :no_editor} end)
      assert {:error, :no_editor} = Terminal.open_editor(pid, "text")
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

      :ok = Terminal.open(pid)
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

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[>4;2m"}, 500

      t0 = System.monotonic_time(:millisecond)
      GenServer.stop(pid, :normal)
      elapsed = System.monotonic_time(:millisecond) - t0

      assert elapsed >= 40
      assert elapsed < 500
    end

    test "skip_raw_mode skips drain entirely" do
      pid = start_terminal(name: nil, tty_fn: fn _ -> :ok end, drain_idle_ms: 5000)

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

      :ok = Terminal.open(pid)
      assert_receive {:tty, "\e[>4;2m"}, 500

      stop_task = Task.async(fn -> GenServer.stop(pid, :normal) end)

      # Wait until disable_keyboard_protocol fires — drain starts immediately after
      assert_receive {:tty, "\e[>4m"}, 500
      send(pid, {:stdin_chunk, "z"})

      Task.await(stop_task, 2000)

      refute_receive {:key_event, _}, 100
    end
  end

  describe "stdin EOF stops terminal" do
    test "terminal stops normally when reader returns :eof" do
      pid = start_terminal(name: nil, auto_start_reader: true, reader_fn: fn -> :eof end)
      ref = Process.monitor(pid)
      :ok = Terminal.open(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end

    test "terminal stops normally when reader returns {:error, reason}" do
      pid = start_terminal(name: nil, auto_start_reader: true, reader_fn: fn -> {:error, :closed} end)
      ref = Process.monitor(pid)
      :ok = Terminal.open(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
    end
  end

  describe "reader exit diagnostics" do
    test "emits telemetry on :eof" do
      test_pid = self()
      handler_id = "test-reader-eof-#{inspect(test_pid)}"

      :telemetry.attach(handler_id, [:octo_pi_tui, :terminal, :reader_exit], &__MODULE__.__reader_exit_forward__/4, %{
        pid: test_pid
      })

      pid = start_terminal(name: nil, auto_start_reader: true, reader_fn: fn -> :eof end)
      :ok = Terminal.open(pid)

      assert_receive {:reader_exit, :eof}, 1_000

      :telemetry.detach(handler_id)
    end

    test "emits telemetry on {:error, reason}" do
      test_pid = self()
      handler_id = "test-reader-err-#{inspect(test_pid)}"

      :telemetry.attach(handler_id, [:octo_pi_tui, :terminal, :reader_exit], &__MODULE__.__reader_exit_forward__/4, %{
        pid: test_pid
      })

      pid = start_terminal(name: nil, auto_start_reader: true, reader_fn: fn -> {:error, :closed} end)
      :ok = Terminal.open(pid)

      assert_receive {:reader_exit, {:error, :closed}}, 1_000

      :telemetry.detach(handler_id)
    end
  end
end
