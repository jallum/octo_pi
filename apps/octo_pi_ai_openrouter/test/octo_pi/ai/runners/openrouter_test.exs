defmodule OctoPi.AI.Runners.OpenRouterTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Runners.OpenRouter

  describe "api/0" do
    test "returns :openai_completions" do
      assert OpenRouter.api() == :openai_completions
    end
  end

  describe "default_base_url/0" do
    test "returns OpenRouter's base URL" do
      assert OpenRouter.default_base_url() == "https://openrouter.ai/api/v1"
    end
  end

  describe "auth/0" do
    test "defaults to OPENROUTER_API_KEY env var" do
      assert OpenRouter.auth() == {:env, "OPENROUTER_API_KEY"}
    end
  end

  describe "validate/1" do
    test "returns :ok for valid config" do
      assert OpenRouter.validate(%{}) == :ok
      assert OpenRouter.validate(%{"base_url" => "https://custom.example.com"}) == :ok
    end

    test "returns error for non-string base_url" do
      assert OpenRouter.validate(%{"base_url" => 123}) == {:error, "base_url must be a string"}
    end
  end
end
