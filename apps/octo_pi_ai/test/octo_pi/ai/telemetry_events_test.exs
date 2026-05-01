defmodule OctoPi.AI.TelemetryEventsTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Auth
  alias OctoPi.AI.ModelRegistry

  defmodule StubRunner do
    @moduledoc false
    @behaviour OctoPi.AI.Runner

    @impl true
    def api, do: :openai_completions
    @impl true
    def default_base_url, do: "http://stub/v1"
    @impl true
    def auth, do: :none
    @impl true
    def validate(_), do: :ok

    @impl true
    def lookup("found", _) do
      {:ok,
       %OctoPi.AI.Model{
         id: "found",
         name: "found",
         api: :openai_completions,
         provider: :stub,
         base_url: "http://stub/v1",
         context_window: 1024,
         max_tokens: 256
       }}
    end

    def lookup("nf", _), do: :not_found
    def lookup(_, _), do: :unsupported

    @impl true
    def discover(_), do: :unsupported
  end

  defp tmp_path do
    p = Path.join(System.tmp_dir!(), "opi-telem-#{System.unique_integer([:positive])}.json")
    on_exit(fn -> File.rm(p) end)
    p
  end

  defp attach(name, events) do
    pid = self()
    handler_id = "telem-test-#{name}-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _ ->
        send(pid, {:telem, event, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  describe "[:octo_pi_ai, :model_registry, :load]" do
    test "emits start + stop with path and counts" do
      attach("load", [
        [:octo_pi_ai, :model_registry, :load, :start],
        [:octo_pi_ai, :model_registry, :load, :stop]
      ])

      path = tmp_path()
      File.write!(path, ~s({"providers": {"stub": {"models": [{"id": "a"}, {"id": "b"}]}}}))

      assert {:ok, _reg} =
               ModelRegistry.load(models_file: path, runners: %{stub: StubRunner})

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :load, :start], %{system_time: _}, %{path: ^path}}

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :load, :stop], %{duration: _},
                      %{path: ^path, runner_count: 1, model_count: 2}}
    end

    test "emits stop with error when load fails" do
      attach("load_err", [[:octo_pi_ai, :model_registry, :load, :stop]])

      path = tmp_path()
      File.write!(path, "{ not json")

      assert {:error, _} = ModelRegistry.load(models_file: path, runners: %{stub: StubRunner})

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :load, :stop], _, %{outcome: :error}}
    end
  end

  describe "[:octo_pi_ai, :model_registry, :resolve]" do
    setup do
      path = tmp_path()
      File.write!(path, ~s({"providers": {"stub": {"models": [{"id": "cached"}]}}}))
      {:ok, reg} = ModelRegistry.load(models_file: path, runners: %{stub: StubRunner})
      {:ok, reg: reg}
    end

    test "cached hit emits :cached outcome", %{reg: reg} do
      attach("resolve_cached", [[:octo_pi_ai, :model_registry, :resolve, :stop]])
      assert {:ok, _} = ModelRegistry.resolve(reg, "stub/cached")

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :resolve, :stop], _,
                      %{ref: "stub/cached", outcome: :cached}}
    end

    test "lookup hit emits :looked_up outcome", %{reg: reg} do
      attach("resolve_lookup", [[:octo_pi_ai, :model_registry, :resolve, :stop]])
      assert {:ok, _} = ModelRegistry.resolve(reg, "stub/found")

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :resolve, :stop], _,
                      %{ref: "stub/found", outcome: :looked_up}}
    end

    test "not_found emits :not_found outcome", %{reg: reg} do
      attach("resolve_nf", [[:octo_pi_ai, :model_registry, :resolve, :stop]])
      assert {:error, _} = ModelRegistry.resolve(reg, "stub/nf")

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :resolve, :stop], _,
                      %{ref: "stub/nf", outcome: :not_found}}
    end

    test "bad_ref emits :bad_ref outcome", %{reg: reg} do
      attach("resolve_bad", [[:octo_pi_ai, :model_registry, :resolve, :stop]])
      assert {:error, {:bad_ref, _}} = ModelRegistry.resolve(reg, "barf")

      assert_receive {:telem, [:octo_pi_ai, :model_registry, :resolve, :stop], _, %{outcome: :bad_ref}}
    end
  end

  describe "[:octo_pi_ai, :runner, :lookup]" do
    setup do
      path = tmp_path()
      File.write!(path, ~s({"providers": {"stub": {"models": []}}}))
      {:ok, reg} = ModelRegistry.load(models_file: path, runners: %{stub: StubRunner})
      {:ok, reg: reg}
    end

    test "emits start + stop with runner + id metadata", %{reg: reg} do
      attach("runner_lookup", [
        [:octo_pi_ai, :runner, :lookup, :start],
        [:octo_pi_ai, :runner, :lookup, :stop]
      ])

      ModelRegistry.resolve(reg, "stub/found")

      assert_receive {:telem, [:octo_pi_ai, :runner, :lookup, :start], _, %{runner: :stub, id: "found"}}

      assert_receive {:telem, [:octo_pi_ai, :runner, :lookup, :stop], _, %{runner: :stub, id: "found", outcome: :ok}}
    end
  end

  describe "[:octo_pi_ai, :auth, :resolve]" do
    test "emits start + stop with strategy and runner_name; never the secret value" do
      attach("auth_resolve", [
        [:octo_pi_ai, :auth, :resolve, :start],
        [:octo_pi_ai, :auth, :resolve, :stop]
      ])

      assert {:ok, _} = Auth.resolve(StubRunner, "instance-name", auth_file: :none)

      assert_receive {:telem, [:octo_pi_ai, :auth, :resolve, :start], _, %{runner: "instance-name"}}

      assert_receive {:telem, [:octo_pi_ai, :auth, :resolve, :stop], _,
                      %{runner: "instance-name", strategy: :none, outcome: :ok}}
    end
  end
end
