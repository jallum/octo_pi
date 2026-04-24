defmodule OctoPi.Coder.Extension.ProviderConfigTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.ProviderConfig
  alias OctoPi.Coder.Extension.ProviderConfig.ModelConfig

  defp sample_config do
    %ProviderConfig{
      id: "my-provider",
      base_url: "https://api.example.com",
      api_key: "sk-test",
      api: :openai_completions,
      models: [
        %ModelConfig{
          id: "my-model",
          name: "My Model",
          context_window: 128_000,
          max_tokens: 4_096,
          reasoning: true,
          input_types: [:text, :image],
          cost: %{
            input_per_million: 3.0,
            output_per_million: 15.0,
            cache_read_per_million: nil,
            cache_write_per_million: nil
          }
        }
      ]
    }
  end

  describe "ProviderConfig struct" do
    test "has expected defaults" do
      config = %ProviderConfig{}
      assert config.api == :openai_completions
      assert config.headers == %{}
      assert config.models == []
    end
  end

  describe "ModelConfig struct" do
    test "has expected defaults" do
      model = %ModelConfig{}
      assert model.reasoning == false
      assert model.input_types == [:text]
      assert model.context_window == 128_000
      assert model.max_tokens == 4_096
    end
  end

  describe "Inspect redaction" do
    test "api_key is redacted in inspect output" do
      config = %ProviderConfig{id: "p1", api_key: "sk-secret-key-123"}
      inspected = inspect(config)
      refute inspected =~ "sk-secret-key-123"
      assert inspected =~ "\"[REDACTED]\""
    end

    test "nil api_key shows nil" do
      config = %ProviderConfig{id: "p1", api_key: nil}
      inspected = inspect(config)
      assert inspected =~ "api_key: nil"
    end
  end

  describe "API.register_provider/2" do
    test "queues provider before bind_core" do
      api = API.new("x")
      config = sample_config()
      {:ok, api} = API.register_provider(api, config)

      assert [{:register, ^config}] = API.pending_providers(api)
    end

    test "queues multiple providers in order" do
      api = API.new("x")
      c1 = %ProviderConfig{id: "p1", base_url: "https://a.com"}
      c2 = %ProviderConfig{id: "p2", base_url: "https://b.com"}

      {:ok, api} = API.register_provider(api, c1)
      {:ok, api} = API.register_provider(api, c2)

      assert [{:register, ^c1}, {:register, ^c2}] = API.pending_providers(api)
    end
  end

  describe "API.unregister_provider/2" do
    test "queues unregistration" do
      api = API.new("x")
      {:ok, api} = API.unregister_provider(api, "my-provider")

      assert [{:unregister, "my-provider"}] = API.pending_providers(api)
    end
  end

  describe "pending_providers after bind_core" do
    test "pending queue survives bind_core" do
      api = API.new("x")
      config = sample_config()
      {:ok, api} = API.register_provider(api, config)

      bound = API.bind_core(api, %{})
      assert [{:register, ^config}] = API.pending_providers(bound)
      assert bound.bound?
    end
  end
end
