defmodule OctoPi.AI.Providers.OpenAI.AuthTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.{Model, StreamOptions}
  alias OctoPi.AI.Providers.OpenAI.Auth

  defp model(provider) do
    %Model{
      id: "x",
      name: "x",
      api: :openai_completions,
      provider: provider,
      base_url: "https://example/v1",
      context_window: 128_000,
      max_tokens: 4_096
    }
  end

  describe "resolve/2" do
    test "explicit opts.api_key wins over env" do
      System.put_env("OPENROUTER_API_KEY", "from-env")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %StreamOptions{api_key: "from-opts"}) ==
               "from-opts"
    end

    test "falls back to OPENROUTER_API_KEY for :openrouter" do
      System.put_env("OPENROUTER_API_KEY", "or-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %StreamOptions{}) == "or-key"
    end

    test "falls back to OPENAI_API_KEY for :openai" do
      System.put_env("OPENAI_API_KEY", "oa-key")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert Auth.resolve(model(:openai), %StreamOptions{}) == "oa-key"
    end

    test "returns nil for unknown providers (e.g. ollama)" do
      assert Auth.resolve(model(:ollama), %StreamOptions{}) == nil
    end

    test "treats empty env var as nil" do
      System.put_env("OPENROUTER_API_KEY", "")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %StreamOptions{}) == nil
    end

    test "empty opts.api_key falls through to env" do
      System.put_env("OPENROUTER_API_KEY", "or-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %StreamOptions{api_key: ""}) == "or-key"
    end
  end
end
