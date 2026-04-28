defmodule OctoPi.Tracer.FormatterTest do
  use ExUnit.Case, async: true

  alias OctoPi.Tracer.Formatter

  describe "format/3" do
    test "produces monotonic_us wall_time_iso [event.name] format" do
      line = Formatter.format([:my_app, :thing, :start], %{}, %{})

      assert line =~ ~r/\A-?\d+ \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z \[my_app\.thing\.start\]\z/
    end

    test "appends measurement key=value pairs" do
      line = Formatter.format([:app, :ev], %{duration: 1234}, %{})

      assert line =~ "duration=1234"
    end

    test "appends metadata key=value pairs" do
      line = Formatter.format([:app, :ev], %{}, %{model: "claude-3"})

      assert line =~ "model=claude-3"
    end

    test "drops telemetry_span_context from output" do
      line = Formatter.format([:app, :ev], %{}, %{telemetry_span_context: make_ref()})

      refute line =~ "telemetry_span_context"
    end

    test "uses inspect for complex metadata values" do
      line = Formatter.format([:app, :ev], %{}, %{ids: [1, 2, 3]})

      assert line =~ "ids=[1, 2, 3]"
    end
  end
end
