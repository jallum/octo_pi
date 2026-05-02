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

    OctoPi.Tracer.register(%{
      id: :tui_render,
      description: "TUI renderer frame timing + markdown render spans",
      events: [
        [:octo_pi_tui, :renderer, :render],
        [:octo_pi_tui, :markdown, :render, :start],
        [:octo_pi_tui, :markdown, :render, :stop]
      ],
      level: :debug
    })

    OctoPi.Tracer.attach_all()

    on_exit(fn ->
      Enum.each(OctoPi.Tracer.registered(), &OctoPi.Tracer.detach(&1.id))
    end)

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

    test "Tracer registers :tui_render with markdown spans" do
      spec = Enum.find(OctoPi.Tracer.registered(), &(&1.id == :tui_render))
      assert spec
      events = spec.events
      assert [:octo_pi_tui, :markdown, :render, :start] in events
      assert [:octo_pi_tui, :markdown, :render, :stop] in events
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

    test "markdown.render.stop event logs via :tui_render" do
      log =
        capture_log([level: :debug], fn ->
          :telemetry.execute(
            [:octo_pi_tui, :markdown, :render, :stop],
            %{duration: 999, text_bytes: 42, line_count: 3},
            %{msg_id: "m1", streaming?: false, width: 80}
          )
        end)

      assert log =~ "octo_pi_tui.markdown.render.stop"
    end
  end
end
