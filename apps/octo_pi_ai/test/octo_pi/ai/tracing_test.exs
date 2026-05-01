defmodule OctoPi.AI.TracingTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Tracing

  setup do
    Tracing.detach()
    on_exit(fn -> Tracing.detach() end)
    :ok
  end

  defp capture_stderr(fun) do
    ExUnit.CaptureIO.capture_io(:stderr, fun)
  end

  describe "attach/0" do
    test "is idempotent — second attach returns {:error, :already_exists}" do
      assert :ok = Tracing.attach()
      assert {:error, :already_exists} = Tracing.attach()
    end

    test "emits one stderr line per telemetry event" do
      Tracing.attach()

      output =
        capture_stderr(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :runner, :lookup, :stop],
            %{duration: 5_000_000},
            %{runner: :lmstudio, id: "qwen3-8b", outcome: :ok}
          )
        end)

      assert output =~ "[trace] octo_pi_ai.runner.lookup.stop"
      assert output =~ "runner=lmstudio"
      assert output =~ "id=qwen3-8b"
      assert output =~ "outcome=ok"
    end

    test "renders duration measurement as `dur=Nms`" do
      Tracing.attach()

      output =
        capture_stderr(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :model_registry, :load, :stop],
            %{duration: System.convert_time_unit(42, :millisecond, :native)},
            %{path: "/tmp/x.json", outcome: :ok, runner_count: 1, model_count: 2}
          )
        end)

      assert output =~ "dur=42ms"
    end
  end

  describe "auth event redaction" do
    test "auth events log strategy + runner but never raw secret keys" do
      Tracing.attach()

      output =
        capture_stderr(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :auth, :resolve, :stop],
            %{duration: 1_000_000},
            %{
              runner: "anthropic-prod",
              strategy: :env,
              outcome: :ok,
              # the implementation should never include these in the output
              api_key: "sk-secret-do-not-leak",
              token: "bearer-secret"
            }
          )
        end)

      assert output =~ "runner=anthropic-prod"
      assert output =~ "strategy=env"
      assert output =~ "outcome=ok"
      refute output =~ "sk-secret-do-not-leak"
      refute output =~ "bearer-secret"
    end
  end

  describe "detach/0" do
    test "is idempotent — second detach is a no-op" do
      Tracing.attach()
      assert :ok = Tracing.detach()
      assert :ok = Tracing.detach()
    end

    test "after detach, no output for events" do
      Tracing.attach()
      Tracing.detach()

      output =
        capture_stderr(fn ->
          :telemetry.execute(
            [:octo_pi_ai, :runner, :lookup, :stop],
            %{duration: 1},
            %{runner: :stub, id: "x", outcome: :ok}
          )
        end)

      assert output == ""
    end
  end

  describe "maybe_attach/0" do
    setup do
      original = Application.get_env(:octo_pi_ai, :trace)

      on_exit(fn ->
        case original do
          nil -> Application.delete_env(:octo_pi_ai, :trace)
          v -> Application.put_env(:octo_pi_ai, :trace, v)
        end
      end)

      :ok
    end

    test "attaches when config :octo_pi_ai, :trace, true is set" do
      Application.put_env(:octo_pi_ai, :trace, true)
      assert :ok = Tracing.maybe_attach()
    end

    test "skips when config and env are unset (and we're in MIX_ENV=test)" do
      Application.delete_env(:octo_pi_ai, :trace)
      assert :skipped = Tracing.maybe_attach()
    end
  end
end
