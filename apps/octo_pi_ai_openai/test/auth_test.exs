defmodule OctoPi.AI.Providers.OpenAI.AuthTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.{CallOptions, Model}
  alias OctoPi.AI.Providers.OpenAI.Auth

  setup do
    # Isolate from any real ~/.octo_pi/auth.json on the developer machine.
    prev = Application.get_env(:octo_pi_ai_openai, :auth_file)
    Application.put_env(:octo_pi_ai_openai, :auth_file, "/nonexistent/octo_pi/auth.json")

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:octo_pi_ai_openai, :auth_file)
        v -> Application.put_env(:octo_pi_ai_openai, :auth_file, v)
      end
    end)

    :ok
  end

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

      assert Auth.resolve(model(:openrouter), %CallOptions{api_key: "from-opts"}) ==
               "from-opts"
    end

    test "falls back to OPENROUTER_API_KEY for :openrouter" do
      System.put_env("OPENROUTER_API_KEY", "or-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %CallOptions{}) == "or-key"
    end

    test "falls back to OPENAI_API_KEY for :openai" do
      System.put_env("OPENAI_API_KEY", "oa-key")
      on_exit(fn -> System.delete_env("OPENAI_API_KEY") end)

      assert Auth.resolve(model(:openai), %CallOptions{}) == "oa-key"
    end

    test "returns nil for unknown providers (e.g. ollama)" do
      assert Auth.resolve(model(:ollama), %CallOptions{}) == nil
    end

    test "treats empty env var as nil" do
      System.put_env("OPENROUTER_API_KEY", "")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %CallOptions{}) == nil
    end

    test "empty opts.api_key falls through to env" do
      System.put_env("OPENROUTER_API_KEY", "or-key")
      on_exit(fn -> System.delete_env("OPENROUTER_API_KEY") end)

      assert Auth.resolve(model(:openrouter), %CallOptions{api_key: ""}) == "or-key"
    end
  end
end
