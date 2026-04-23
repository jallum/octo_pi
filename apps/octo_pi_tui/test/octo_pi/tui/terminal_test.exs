defmodule OctoPi.TUI.TerminalTest do
  use ExUnit.Case, async: false

  alias OctoPi.TUI.{Events, Terminal}

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
      assert %{width: 100, height: 30} = Terminal.state(pid)
    end
  end

  describe "feed_chunk/2" do
    test "broadcasts the chunk via Events under :stdin_chunk topic" do
      pid = start_terminal()
      {:ok, _} = Registry.register(Events, :stdin_chunk, nil)
      :ok = Terminal.feed_chunk(pid, "abc")
      assert_receive {:stdin_chunk, "abc"}, 500
    end

    test "forwards multiple chunks in order" do
      pid = start_terminal()
      {:ok, _} = Registry.register(Events, :stdin_chunk, nil)
      :ok = Terminal.feed_chunk(pid, "a")
      :ok = Terminal.feed_chunk(pid, "b")
      assert_receive {:stdin_chunk, "a"}, 500
      assert_receive {:stdin_chunk, "b"}, 500
    end
  end

  describe "SIGWINCH handling" do
    test "simulated sigwinch broadcasts a resize event with new dimensions" do
      pid = start_terminal(dimensions: {80, 24})
      {:ok, _} = Registry.register(Events, :resize, nil)

      # Drive the resize with an explicit dims override — in
      # production we'd read :io.columns/0, but tests inject.
      :ok = Terminal.simulate_resize(pid, 120, 40)

      assert_receive {:resize, 120, 40}, 500
      assert %{width: 120, height: 40} = Terminal.state(pid)
    end
  end

  describe "terminate/2" do
    test "calls raw_mode.exit on normal shutdown" do
      test_pid = self()

      raw_mode = fn action ->
        send(test_pid, {:raw_mode, action})
        :ok
      end

      # Pass raw_mode as a 1-arg fn that accepts :enter / :exit.
      pid =
        start_terminal(
          skip_raw_mode: false,
          raw_mode_fn: raw_mode
        )

      assert_receive {:raw_mode, :enter}, 500
      GenServer.stop(pid, :normal)
      assert_receive {:raw_mode, :exit}, 500
    end
  end
end
