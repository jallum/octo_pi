defmodule OctoPi.AI.Providers.OpenAI.TracerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  @events [
    [:octo_pi_ai, :request, :start],
    [:octo_pi_ai, :request, :stop],
    [:octo_pi_ai, :request, :exception]
  ]

  setup do
    OctoPi.Tracer.register(%{id: :ai_core, description: "", events: @events, level: :info})
    OctoPi.Tracer.attach_all()
    on_exit(fn -> OctoPi.Tracer.detach(:ai_core) end)
    :ok
  end

  describe "handle_event/4" do
    test "forwards :request, :start events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :request, :start],
            %{system_time: 0},
            %{api: :openai_completions, model: "gpt-4o"}
          )
        end)

      assert log =~ "octo_pi_ai.request.start"
      assert log =~ "openai_completions"
      assert log =~ "gpt-4o"
    end

    test "forwards :request, :stop events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :request, :stop],
            %{duration: 100, input_tokens: 10, output_tokens: 20, total_tokens: 30},
            %{api: :openai_completions, model: "gpt-4o", stop_reason: :stop}
          )
        end)

      assert log =~ "octo_pi_ai.request.stop"
    end

    test "forwards :request, :exception events to the logger" do
      log =
        capture_log(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :request, :exception],
            %{duration: 50},
            %{api: :openai_completions, model: "gpt-4o", kind: :error, reason: :timeout}
          )
        end)

      assert log =~ "octo_pi_ai.request.exception"
    end
  end
end
