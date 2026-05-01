defmodule OctoPi.AI.Runners.AnthropicTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.ModelRegistry
  alias OctoPi.AI.Runner
  alias OctoPi.AI.RunnerRegistry
  alias OctoPi.AI.Runners.Anthropic

  describe "behaviour" do
    test "implements OctoPi.AI.Runner" do
      Code.ensure_loaded!(Anthropic)
      callbacks = Runner.behaviour_info(:callbacks)

      Enum.each(callbacks, fn {name, arity} ->
        assert function_exported?(Anthropic, name, arity),
               "expected #{inspect(Anthropic)}.#{name}/#{arity} to be exported"
      end)
    end
  end

  describe "callbacks" do
    test "api/0" do
      assert Anthropic.api() == :anthropic_messages
    end

    test "default_base_url/0" do
      assert Anthropic.default_base_url() == "https://api.anthropic.com/v1"
    end

    test "auth/0 defaults to ANTHROPIC_API_KEY env var" do
      assert Anthropic.auth() == {:env, "ANTHROPIC_API_KEY"}
    end

    test "validate/1 accepts an empty config" do
      assert :ok = Anthropic.validate(%{})
    end

    test "validate/1 accepts base_url override" do
      assert :ok = Anthropic.validate(%{"base_url" => "https://proxy.example/anthropic"})
    end

    test "validate/1 rejects non-string base_url" do
      assert {:error, _} = Anthropic.validate(%{"base_url" => 42})
    end

    test "lookup/2 is :unsupported (no live /models endpoint)" do
      assert :unsupported = Anthropic.lookup("claude-opus-4-7", %{})
    end

    test "discover/1 is :unsupported" do
      assert :unsupported = Anthropic.discover(%{})
    end
  end

  describe "registration" do
    test "is registered in OctoPi.AI.RunnerRegistry under :anthropic" do
      assert RunnerRegistry.lookup(:anthropic) == Anthropic
    end
  end

  describe "ModelRegistry integration via global default" do
    setup do
      path = Path.join(System.tmp_dir!(), "opi-anthropic-#{System.unique_integer([:positive])}.json")
      on_exit(fn -> File.rm(path) end)

      File.write!(path, ~s({
        "providers": {
          "anthropic": {
            "models": [
              {"id": "claude-opus-4-7", "context_window": 200000, "max_tokens": 32000, "reasoning": true}
            ]
          }
        }
      }))

      {:ok, path: path}
    end

    test "loads anthropic entries using RunnerRegistry as default", %{path: path} do
      # No :runners passed — ModelRegistry uses RunnerRegistry.list/0
      assert {:ok, reg} = ModelRegistry.load(models_file: path)

      m = ModelRegistry.find(reg, :anthropic, "claude-opus-4-7")
      assert m.api == :anthropic_messages
      assert m.provider == :anthropic
      assert m.base_url == "https://api.anthropic.com/v1"
      assert m.context_window == 200_000
      assert m.max_tokens == 32_000
      assert m.reasoning == true
    end

    test "resolve uses runner-default base_url", %{path: path} do
      assert {:ok, reg} = ModelRegistry.load(models_file: path)
      assert {:ok, m} = ModelRegistry.resolve(reg, "anthropic/claude-opus-4-7")
      assert m.base_url == "https://api.anthropic.com/v1"
    end

    test "resolve unknown id returns :unsupported (Anthropic has no live catalog)", %{path: path} do
      assert {:ok, reg} = ModelRegistry.load(models_file: path)

      assert {:error, {:unsupported, :anthropic, "made-up-id"}} =
               ModelRegistry.resolve(reg, "anthropic/made-up-id")
    end
  end
end
