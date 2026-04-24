defmodule OctoPi.AI.Providers.OpenAI.CompatTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.OpenAI.Compat

  defp model(attrs \\ %{}) do
    %Model{
      id: Map.get(attrs, :id, "gpt-4o"),
      name: Map.get(attrs, :name, "GPT-4o"),
      api: :openai_completions,
      provider: Map.get(attrs, :provider, :openai),
      base_url: Map.get(attrs, :base_url, "https://api.openai.com/v1"),
      context_window: 128_000,
      max_tokens: 16_384,
      reasoning: Map.get(attrs, :reasoning, false),
      compat: Map.get(attrs, :compat, nil)
    }
  end

  describe "detect/1 — standard OpenAI" do
    test "returns standard defaults for OpenAI" do
      compat = Compat.detect(model())

      assert compat.supports_store == true
      assert compat.supports_developer_role == true
      assert compat.supports_reasoning_effort == true
      assert compat.reasoning_effort_map == %{}
      assert compat.supports_usage_in_streaming == true
      assert compat.max_tokens_field == :max_completion_tokens
      assert compat.requires_tool_result_name == false
      assert compat.requires_assistant_after_tool_result == false
      assert compat.requires_thinking_as_text == false
      assert compat.thinking_format == :openai
      assert compat.supports_strict_mode == true
      assert compat.cache_control_format == nil
      assert compat.send_session_affinity_headers == false
      assert compat.zai_tool_stream == false
      assert compat.open_router_routing == %{}
      assert compat.vercel_gateway_routing == %{}
    end
  end

  describe "detect/1 — non-standard providers" do
    test "cerebras by provider atom" do
      compat = Compat.detect(model(%{provider: :cerebras}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
      assert compat.supports_reasoning_effort == true
      assert compat.thinking_format == :openai
    end

    test "cerebras by base_url" do
      compat = Compat.detect(model(%{base_url: "https://api.cerebras.ai/v1"}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
    end

    test "xai/grok by provider atom" do
      compat = Compat.detect(model(%{provider: :xai}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
      assert compat.supports_reasoning_effort == false
      assert compat.thinking_format == :openai
    end

    test "xai/grok by base_url" do
      compat = Compat.detect(model(%{base_url: "https://api.x.ai/v1"}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
      assert compat.supports_reasoning_effort == false
    end

    test "deepseek by base_url" do
      compat = Compat.detect(model(%{base_url: "https://api.deepseek.com/v1"}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
      assert compat.supports_reasoning_effort == true
    end

    test "chutes.ai uses max_tokens field" do
      compat = Compat.detect(model(%{base_url: "https://api.chutes.ai/v1"}))

      assert compat.max_tokens_field == :max_tokens
      assert compat.supports_store == false
      assert compat.supports_developer_role == false
    end

    test "opencode by provider atom" do
      compat = Compat.detect(model(%{provider: :opencode}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
    end

    test "opencode by base_url" do
      compat = Compat.detect(model(%{base_url: "https://api.opencode.ai/v1"}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
    end
  end

  describe "detect/1 — zai" do
    test "zai by provider atom" do
      compat = Compat.detect(model(%{provider: :zai}))

      assert compat.supports_store == false
      assert compat.supports_developer_role == false
      assert compat.supports_reasoning_effort == false
      assert compat.thinking_format == :zai
    end

    test "zai by base_url" do
      compat = Compat.detect(model(%{base_url: "https://api.z.ai/v1"}))

      assert compat.thinking_format == :zai
      assert compat.supports_reasoning_effort == false
    end
  end

  describe "detect/1 — openrouter" do
    test "openrouter by provider atom" do
      compat = Compat.detect(model(%{provider: :openrouter}))

      assert compat.thinking_format == :openrouter
      assert compat.supports_store == true
      assert compat.supports_developer_role == true
      assert compat.cache_control_format == nil
    end

    test "openrouter by base_url" do
      compat = Compat.detect(model(%{base_url: "https://openrouter.ai/api/v1"}))

      assert compat.thinking_format == :openrouter
    end

    test "openrouter with anthropic model gets anthropic cache_control_format" do
      compat =
        Compat.detect(model(%{provider: :openrouter, id: "anthropic/claude-sonnet-4-5"}))

      assert compat.cache_control_format == :anthropic
    end

    test "openrouter with non-anthropic model gets nil cache_control_format" do
      compat = Compat.detect(model(%{provider: :openrouter, id: "openai/gpt-4o"}))

      assert compat.cache_control_format == nil
    end
  end

  describe "detect/1 — groq" do
    test "groq has standard reasoning effort" do
      compat = Compat.detect(model(%{provider: :groq}))

      assert compat.supports_reasoning_effort == true
      assert compat.reasoning_effort_map == %{}
    end

    test "groq qwen3-32b maps all levels to default" do
      compat = Compat.detect(model(%{provider: :groq, id: "qwen/qwen3-32b"}))

      assert compat.reasoning_effort_map == %{
               minimal: "default",
               low: "default",
               medium: "default",
               high: "default",
               xhigh: "default"
             }
    end
  end

  describe "resolve/1 — merge explicit compat" do
    test "returns detected defaults when model.compat is nil" do
      m = model()
      assert Compat.resolve(m) == Compat.detect(m)
    end

    test "explicit compat overrides detected values" do
      m =
        model(%{
          compat: %{
            supports_store: false,
            thinking_format: :qwen,
            requires_tool_result_name: true
          }
        })

      compat = Compat.resolve(m)

      assert compat.supports_store == false
      assert compat.thinking_format == :qwen
      assert compat.requires_tool_result_name == true
      # Non-overridden fields keep detected defaults
      assert compat.supports_developer_role == true
      assert compat.max_tokens_field == :max_completion_tokens
    end

    test "nil values in explicit compat fall through to detected" do
      m = model(%{compat: %{supports_store: nil, thinking_format: nil}})
      compat = Compat.resolve(m)

      assert compat.supports_store == true
      assert compat.thinking_format == :openai
    end

    test "explicit compat on non-standard provider" do
      m =
        model(%{
          provider: :xai,
          compat: %{supports_store: true}
        })

      compat = Compat.resolve(m)

      # Overridden
      assert compat.supports_store == true
      # Still detected as xai
      assert compat.supports_reasoning_effort == false
      assert compat.supports_developer_role == false
    end
  end
end
