defmodule OctoPi.TUI.TracerHandlersTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  # Re-register and attach in case a prior test suite cleared the ETS table.
  setup_all do
    OctoPi.Tracer.register(%{
      id: :tui_events,
      description: "TUI stdin byte, ANSI sequence, and key events",
      events: [
        [:octo_pi_tui, :stdin, :chunk],
        [:octo_pi_tui, :stdin, :sequence],
        [:octo_pi_tui, :key, :event]
      ],
      level: :debug
    })

    OctoPi.Tracer.register(%{
      id: :tui_raw,
      description: "TTY pipeline trace: reader, stdin, key, terminal, raw_mode (high-frequency — expect volume)",
      events: [
        [:octo_pi_tui, :stdin, :chunk],
        [:octo_pi_tui, :stdin, :sequence],
        [:octo_pi_tui, :key, :event],
        [:octo_pi_tui, :raw_mode, :exit, :stop]
      ],
      level: :debug
    })

    OctoPi.Tracer.attach_all()
    :ok
  end

  describe "registered handlers" do
    test "Events.Tracer registers :tui_events with OctoPi.Tracer" do
      ids = Enum.map(OctoPi.Tracer.registered(), & &1.id)
      assert :tui_events in ids
    end

    test "Tracer registers :tui_raw with OctoPi.Tracer" do
      ids = Enum.map(OctoPi.Tracer.registered(), & &1.id)
      assert :tui_raw in ids
    end

    test ":tui_raw description mentions high-frequency" do
      spec = Enum.find(OctoPi.Tracer.registered(), &(&1.id == :tui_raw))
      assert spec.description =~ "high-frequency"
    end
  end

  describe "log output" do
    test "stdin chunk event logs with tracer domain at debug level" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:octo_pi_tui, :stdin, :chunk], %{byte_count: 3}, %{bytes: "abc"})
        end)

      assert log =~ "octo_pi_tui.stdin.chunk"
    end

    test "key event logs with tracer domain at debug level" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:octo_pi_tui, :key, :event], %{}, %{parsed: :enter})
        end)

      assert log =~ "octo_pi_tui.key.event"
    end

    test "raw_mode exit stop event logs via :tui_raw at debug level" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute([:octo_pi_tui, :raw_mode, :exit, :stop], %{}, %{})
        end)

      assert log =~ "octo_pi_tui.raw_mode.exit.stop"
    end
  end
end
