defmodule OctoPi.AI.Providers.OpenAI.TracerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @events [
    [:octo_pi_ai_openai, :request, :start],
    [:octo_pi_ai_openai, :request, :stop],
    [:octo_pi_ai_openai, :request, :exception]
  ]

  setup do
    OctoPi.Tracer.register(%{id: :openai, description: "", events: @events, level: :info})
    OctoPi.Tracer.attach_all()
    on_exit(fn -> OctoPi.Tracer.detach(:openai) end)
    :ok
  end

  describe "handle_event/4" do
    test "forwards :request, :start events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai_openai, :request, :start],
            %{system_time: 0},
            %{model: "gpt-4o"}
          )
        end)

      assert log =~ "octo_pi_ai_openai.request.start"
    end

    test "forwards :request, :stop events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai_openai, :request, :stop],
            %{duration: 100, input_tokens: 10, output_tokens: 20, total_tokens: 30},
            %{model: "gpt-4o", stop_reason: :end_turn}
          )
        end)

      assert log =~ "octo_pi_ai_openai.request.stop"
    end

    test "forwards :request, :exception events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai_openai, :request, :exception],
            %{duration: 50},
            %{model: "gpt-4o", kind: :error, reason: :timeout}
          )
        end)

      assert log =~ "octo_pi_ai_openai.request.exception"
    end
  end
end
