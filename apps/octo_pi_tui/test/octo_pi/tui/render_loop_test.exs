defmodule OctoPi.TUI.RenderLoopTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.RenderLoop

  # Use a long tick so messages sent before assert_receive land in the
  # pending slot before the first tick fires, and a short tick so the
  # tick fires well within our assert_receive timeout.
  @burst_tick_ms 50
  @fast_tick_ms 5

  defp start(opts \\ []) do
    test_pid = self()
    write_fn = Keyword.get(opts, :terminal, fn bytes -> send(test_pid, {:wrote, bytes}) end)

    {:ok, pid} =
      RenderLoop.start_link(
        Keyword.merge(
          [
            width: 80,
            height: 24,
            terminal: write_fn,
            tick_ms: @fast_tick_ms
          ],
          opts
        )
      )

    pid
  end

  defp strip_csi(binary) do
    Regex.replace(~r/\e\[[0-9;?]*[A-Za-z]/, binary, "")
  end

  describe "basic render" do
    test "render message causes bytes to be written on the next tick" do
      pid = start()
      send(pid, {:render, ["hello"], ""})
      assert_receive {:wrote, bytes}, 200
      assert strip_csi(bytes) =~ "hello"
    end

    test "no render message → no write" do
      _pid = start()
      refute_receive {:wrote, _}, @fast_tick_ms * 3
    end
  end

  describe "burst collapse" do
    test "rapid render messages collapse to the last frame per tick" do
      pid = start(tick_ms: @burst_tick_ms)

      # Send three frames before the tick fires (tick_ms is 50ms)
      send(pid, {:render, ["frame1"], ""})
      send(pid, {:render, ["frame2"], ""})
      send(pid, {:render, ["frame3"], ""})

      assert_receive {:wrote, bytes}, 200
      text = strip_csi(bytes)
      assert text =~ "frame3"
      refute text =~ "frame1"

      # Only one write should have happened for the burst
      refute_receive {:wrote, _}, @burst_tick_ms
    end
  end

  describe "final-frame guarantee" do
    test "a pending render always fires on the next tick even with no further messages" do
      pid = start(tick_ms: @fast_tick_ms)

      send(pid, {:render, ["first"], ""})
      assert_receive {:wrote, bytes1}, 200
      assert strip_csi(bytes1) =~ "first"

      send(pid, {:render, ["second"], ""})
      assert_receive {:wrote, bytes2}, 200
      assert strip_csi(bytes2) =~ "second"
    end
  end

  describe "resize" do
    test "resize followed by render triggers a full redraw with clear-screen" do
      pid = start()
      # Prime with an initial render so the renderer has a previous frame
      send(pid, {:render, ["before"], ""})
      assert_receive {:wrote, _}, 200

      send(pid, {:resize, 100, 30})
      send(pid, {:render, ["after resize"], ""})
      assert_receive {:wrote, bytes}, 200
      assert bytes =~ "\e[2J"
      assert strip_csi(bytes) =~ "after resize"
    end
  end

  describe "stop" do
    test "stop message causes the task to exit normally" do
      pid = start()
      ref = Process.monitor(pid)
      send(pid, :stop)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 200
    end
  end

  describe "telemetry" do
    test "emits [:octo_pi_tui, :renderer, :render] on each tick" do
      test_pid = self()

      :telemetry.attach(
        "render-loop-test-#{inspect(self())}",
        [:octo_pi_tui, :renderer, :render],
        fn _event, measurements, metadata, _config ->
          send(test_pid, {:telemetry, measurements, metadata})
        end,
        nil
      )

      on_exit(fn ->
        :telemetry.detach("render-loop-test-#{inspect(test_pid)}")
      end)

      pid = start()
      send(pid, {:render, ["hello"], ""})

      assert_receive {:telemetry, measurements, metadata}, 200
      assert is_integer(measurements.duration)
      assert is_integer(measurements.byte_count)
      assert is_integer(measurements.lines_changed)
      assert metadata.mode in [:first, :full, :diff, :noop]
      assert metadata.line_count == 1
    end
  end
end
