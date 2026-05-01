defmodule OctoPi.AI.ModelRegistryTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Model
  alias OctoPi.AI.ModelRegistry
  alias OctoPi.AI.Runner

  defmodule StubRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :openai_completions
    @impl true
    def default_base_url, do: "http://stub.local/v1"
    @impl true
    def auth, do: :none
    @impl true
    def validate(_), do: :ok

    @impl true
    def lookup("found-" <> rest, _config) do
      {:ok,
       %Model{
         id: "found-" <> rest,
         name: "Stub " <> rest,
         api: :openai_completions,
         provider: :stub,
         base_url: "http://stub.local/v1",
         context_window: 8192,
         max_tokens: 1024
       }}
    end

    def lookup("nf-" <> _, _config), do: :not_found
    def lookup(_, _), do: :unsupported

    @impl true
    def discover(_), do: :unsupported
  end

  defmodule UnsupportedRunner do
    @moduledoc false
    @behaviour Runner

    @impl true
    def api, do: :anthropic_messages
    @impl true
    def default_base_url, do: "https://api.example.com"
    @impl true
    def auth, do: :none
    @impl true
    def validate(_), do: :ok
    @impl true
    def lookup(_, _), do: :unsupported
    @impl true
    def discover(_), do: :unsupported
  end

  @runners %{stub: StubRunner, supplier: UnsupportedRunner}

  defp tmp_path(name) do
    path = Path.join(System.tmp_dir!(), "opi-models-#{System.unique_integer([:positive])}-#{name}.json")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp write_json(path, json), do: File.write!(path, json)

  describe "load/1" do
    test "missing file → empty registry" do
      path = tmp_path("missing")
      assert {:ok, reg} = ModelRegistry.load(models_file: path, runners: @runners)
      assert ModelRegistry.all(reg) == []
      assert ModelRegistry.runners(reg) == []
    end

    test ":none models_file → empty registry" do
      assert {:ok, reg} = ModelRegistry.load(models_file: :none, runners: @runners)
      assert ModelRegistry.all(reg) == []
    end

    test "loads a runner with two models, applying defaults" do
      path = tmp_path("two")

      write_json(path, ~s({
        "providers": {
          "stub": {
            "models": [
              { "id": "small" },
              { "id": "big", "context_window": 200000, "max_tokens": 8000, "reasoning": true }
            ]
          }
        }
      }))

      assert {:ok, reg} = ModelRegistry.load(models_file: path, runners: @runners)
      assert ModelRegistry.runners(reg) == [:stub]

      models = ModelRegistry.models(reg, :stub)
      assert length(models) == 2

      small = ModelRegistry.find(reg, :stub, "small")
      assert small.id == "small"
      assert small.name == "small"
      assert small.api == :openai_completions
      assert small.provider == :stub
      assert small.base_url == "http://stub.local/v1"
      assert small.context_window == 128_000
      assert small.max_tokens == 16_384
      assert small.reasoning == false

      big = ModelRegistry.find(reg, :stub, "big")
      assert big.context_window == 200_000
      assert big.max_tokens == 8_000
      assert big.reasoning == true
    end

    test "renamed key uses runner field" do
      path = tmp_path("rename")

      write_json(path, ~s({
        "providers": {
          "stub-laptop": {
            "runner": "stub",
            "base_url": "http://laptop.local/v1",
            "models": [{ "id": "qwen" }]
          }
        }
      }))

      assert {:ok, reg} = ModelRegistry.load(models_file: path, runners: @runners)
      assert ModelRegistry.runners(reg) == [:"stub-laptop"]
      qwen = ModelRegistry.find(reg, :"stub-laptop", "qwen")
      assert qwen.provider == :"stub-laptop"
      assert qwen.base_url == "http://laptop.local/v1"
    end

    test "unknown runner key without 'runner' field is an error" do
      path = tmp_path("unknown")
      write_json(path, ~s({"providers": {"made-up": {"models": [{"id": "x"}]}}}))
      assert {:error, {:unknown_runner, "made-up"}} = ModelRegistry.load(models_file: path, runners: @runners)
    end

    test "model entry without id is an error" do
      path = tmp_path("noid")
      write_json(path, ~s({"providers": {"stub": {"models": [{}]}}}))

      assert {:error, {:invalid_model, "stub", _, "missing id"}} =
               ModelRegistry.load(models_file: path, runners: @runners)
    end

    test "malformed JSON → parse error" do
      path = tmp_path("malformed")
      write_json(path, "{ not valid")
      assert {:error, {:parse, _}} = ModelRegistry.load(models_file: path, runners: @runners)
    end

    test "top-level not an object → schema error" do
      path = tmp_path("toparr")
      write_json(path, "[]")
      assert {:error, {:schema, _}} = ModelRegistry.load(models_file: path, runners: @runners)
    end

    test "providers section missing → schema error" do
      path = tmp_path("nop")
      write_json(path, "{}")
      assert {:error, {:schema, _}} = ModelRegistry.load(models_file: path, runners: @runners)
    end
  end

  describe "find/3" do
    setup do
      path = tmp_path("find")
      write_json(path, ~s({"providers": {"stub": {"models": [{"id": "m1"}]}}}))
      {:ok, reg} = ModelRegistry.load(models_file: path, runners: @runners)
      {:ok, reg: reg}
    end

    test "hit returns Model", %{reg: reg} do
      assert %Model{id: "m1"} = ModelRegistry.find(reg, :stub, "m1")
    end

    test "miss returns nil", %{reg: reg} do
      assert ModelRegistry.find(reg, :stub, "nope") == nil
    end
  end

  describe "resolve/2" do
    setup do
      path = tmp_path("resolve")
      write_json(path, ~s({"providers": {"stub": {"models": [{"id": "m1"}]}}}))
      {:ok, reg} = ModelRegistry.load(models_file: path, runners: @runners)
      {:ok, reg: reg}
    end

    test "hit on cached model", %{reg: reg} do
      assert {:ok, %Model{id: "m1"}} = ModelRegistry.resolve(reg, "stub/m1")
    end

    test "bare id returns helpful error", %{reg: reg} do
      assert {:error, {:bad_ref, "m1"}} = ModelRegistry.resolve(reg, "m1")
    end

    test "miss falls through to runner.lookup → ok", %{reg: reg} do
      assert {:ok, %Model{id: "found-thing", name: "Stub thing"}} =
               ModelRegistry.resolve(reg, "stub/found-thing")
    end

    test "miss + runner returns :not_found", %{reg: reg} do
      assert {:error, {:not_found, :stub, "nf-x"}} = ModelRegistry.resolve(reg, "stub/nf-x")
    end

    test "miss + runner returns :unsupported", %{reg: reg} do
      assert {:error, {:unsupported, :stub, "anything-else"}} =
               ModelRegistry.resolve(reg, "stub/anything-else")
    end

    test "unknown runner in ref", %{reg: reg} do
      assert {:error, {:unknown_runner, "made-up"}} = ModelRegistry.resolve(reg, "made-up/x")
    end
  end
end
