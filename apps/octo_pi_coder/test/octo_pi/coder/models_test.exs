defmodule OctoPi.Coder.ModelsTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Models

  describe "find/2" do
    test "resolves an Anthropic Claude model with the messages API" do
      assert %Model{
               id: "claude-haiku-4-5",
               provider: :anthropic,
               api: :anthropic_messages,
               base_url: "https://api.anthropic.com/v1",
               context_window: 200_000
             } = Models.find(:anthropic, "claude-haiku-4-5")
    end

    test "applies sonnet override (max_tokens 64k)" do
      assert %Model{max_tokens: 64_000} = Models.find(:anthropic, "claude-sonnet-4-5")
    end

    test "applies opus override (reasoning, max_tokens 32k)" do
      m = Models.find(:anthropic, "claude-opus-4-7")
      assert m.reasoning == true
      assert m.max_tokens == 32_000
    end

    test "resolves an Ollama model via OpenAI-completions API" do
      assert %Model{
               provider: :ollama,
               api: :openai_completions,
               base_url: "http://localhost:1234/v1"
             } = Models.find(:ollama, "qwen3.5:latest")
    end

    test "returns nil for unknown providers" do
      assert Models.find(:google, "gemini-2.5-flash") == nil
      assert Models.find(:openai, "gpt-4") == nil
    end

    test "returns nil for non-binary ids" do
      assert Models.find(:anthropic, nil) == nil
    end
  end

  describe "resolve/1 (id-only sniffing)" do
    test "claude-* routes to Anthropic" do
      assert %Model{provider: :anthropic} = Models.resolve("claude-haiku-4-5")
    end

    test "non-claude ids fall through to Ollama" do
      assert %Model{provider: :ollama} = Models.resolve("qwen3.5:latest")
    end
  end

  describe "Context default find_model" do
    test "resolves a real Anthropic model without explicit injection" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert %Model{provider: :anthropic} = ctx.find_model.(:anthropic, "claude-haiku-4-5")
    end

    test "returns nil for unknown providers (no longer a hard nil_model stub)" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.find_model.(:google, "gemini-2.5-flash") == nil
    end
  end
end
