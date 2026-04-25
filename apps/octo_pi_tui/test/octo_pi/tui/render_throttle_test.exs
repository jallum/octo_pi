defmodule OctoPi.TUI.RenderThrottleTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.RenderThrottle

  describe "new/1" do
    test "creates throttle with default interval" do
      t = RenderThrottle.new()
      assert t.min_interval_ms == 16
      assert t.render_count == 0
      assert t.last_render_at == nil
    end

    test "accepts custom interval" do
      t = RenderThrottle.new(min_interval_ms: 32)
      assert t.min_interval_ms == 32
    end
  end

  describe "should_render?/1" do
    test "allows first render" do
      t = RenderThrottle.new()
      assert {true, _} = RenderThrottle.should_render?(t)
    end

    test "allows render after interval has elapsed" do
      t = RenderThrottle.new(min_interval_ms: 0)
      {true, t} = RenderThrottle.should_render?(t)
      {true, _} = RenderThrottle.should_render?(t)
    end

    test "skips render within interval" do
      t = RenderThrottle.new(min_interval_ms: 1000)
      {true, t} = RenderThrottle.should_render?(t)
      t = RenderThrottle.record_render(t)
      {false, _} = RenderThrottle.should_render?(t)
    end
  end

  describe "record_render/1" do
    test "increments render count" do
      t = RenderThrottle.new()
      t = RenderThrottle.record_render(t)
      assert t.render_count == 1
      t = RenderThrottle.record_render(t)
      assert t.render_count == 2
    end

    test "updates last render timestamp" do
      t = RenderThrottle.new()
      t = RenderThrottle.record_render(t)
      assert t.last_render_at
    end
  end

  describe "metrics/1" do
    test "returns render count and skipped count" do
      t = RenderThrottle.new(min_interval_ms: 1000)
      {true, t} = RenderThrottle.should_render?(t)
      t = RenderThrottle.record_render(t)
      {false, t} = RenderThrottle.should_render?(t)

      metrics = RenderThrottle.metrics(t)
      assert metrics.render_count == 1
      assert metrics.skip_count == 1
    end
  end

  describe "check_width_overflow/3" do
    test "returns :ok when all lines fit" do
      lines = ["hello", "world"]
      assert :ok = RenderThrottle.check_width_overflow(lines, 10)
    end

    test "returns overflow info when lines exceed width" do
      lines = ["short", "this line is too long for width"]
      assert {:overflow, overflows} = RenderThrottle.check_width_overflow(lines, 10)
      assert length(overflows) == 1
      [{idx, len}] = overflows
      assert idx == 1
      assert len > 10
    end

    test "ignores ANSI escape codes in width calculation" do
      lines = ["\e[31mhello\e[0m"]
      assert :ok = RenderThrottle.check_width_overflow(lines, 5)
    end
  end
end
