defmodule OctoPi.Tracer.FormatterTest do
  use ExUnit.Case, async: true

  alias OctoPi.Tracer.Formatter

  defp base, do: System.monotonic_time(:microsecond)

  describe "format/4" do
    test "produces +NNNNN.NNNNNN wall_time_iso [event.name] format" do
      line = Formatter.format([:my_app, :thing, :start], %{}, %{}, base())

      assert line =~
               ~r/\A\+\s*\d+\.\d{6} \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z \[my_app\.thing\.start\]\z/
    end

    test "elapsed is non-negative and dot-aligned in a 5+1+6 field" do
      b = base()
      line = Formatter.format([:app, :ev], %{}, %{}, b)
      [_, s_str, frac_str] = Regex.run(~r/\A\+\s*(\d+)\.(\d{6}) /, line)
      assert String.to_integer(s_str) >= 0
      assert String.length(frac_str) == 6
    end

    test "appends measurement key=value pairs" do
      line = Formatter.format([:app, :ev], %{duration: 1234}, %{}, base())

      assert line =~ "duration=1234"
    end

    test "appends metadata key=value pairs" do
      line = Formatter.format([:app, :ev], %{}, %{model: "claude-3"}, base())

      assert line =~ "model=claude-3"
    end

    test "drops telemetry_span_context from output" do
      line = Formatter.format([:app, :ev], %{}, %{telemetry_span_context: make_ref()}, base())

      refute line =~ "telemetry_span_context"
    end

    test "uses inspect for complex metadata values" do
      line = Formatter.format([:app, :ev], %{}, %{ids: [1, 2, 3]}, base())

      assert line =~ "ids=[1, 2, 3]"
    end
  end
end
