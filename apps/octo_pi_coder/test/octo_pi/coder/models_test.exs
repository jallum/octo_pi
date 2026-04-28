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

    test "resolves an OpenAI model via OpenAI-completions API" do
      assert %Model{
               provider: :openai,
               api: :openai_completions,
               base_url: "https://api.openai.com/v1"
             } = Models.find(:openai, "gpt-4o")
    end

    test "OpenAI o-series and gpt-5 ids set reasoning: true" do
      assert %Model{reasoning: true} = Models.find(:openai, "o3-mini")
      assert %Model{reasoning: true} = Models.find(:openai, "gpt-5-mini")
      assert %Model{reasoning: false} = Models.find(:openai, "gpt-4o")
    end

    test "resolves a Google Gemini model — nominal until an octo_pi_ai_google ships" do
      m = Models.find(:google, "gemini-2.5-flash")
      assert m.provider == :google
      assert m.api == :google_generative_ai
      assert m.base_url =~ "googleapis.com"
      assert m.reasoning == true
      assert :image in m.input
    end

    test "Gemini 2.5 Pro overrides bump max_tokens" do
      assert %Model{max_tokens: 65_536, reasoning: true} =
               Models.find(:google, "gemini-2.5-pro")
    end

    test "returns nil for unmodelled providers" do
      assert Models.find(:azure, "anything") == nil
    end

    test "returns nil for non-binary ids" do
      assert Models.find(:anthropic, nil) == nil
    end
  end

  describe "resolve/1 (id-only sniffing)" do
    test "claude-* routes to Anthropic" do
      assert %Model{provider: :anthropic} = Models.resolve("claude-haiku-4-5")
    end

    test "gemini-* routes to Google" do
      assert %Model{provider: :google} = Models.resolve("gemini-2.5-flash")
    end

    test "gpt-* routes to OpenAI" do
      assert %Model{provider: :openai} = Models.resolve("gpt-4o")
    end

    test "o-series ids route to OpenAI" do
      assert %Model{provider: :openai} = Models.resolve("o3-mini")
    end

    test "non-claude / non-gemini / non-gpt ids fall through to Ollama" do
      assert %Model{provider: :ollama} = Models.resolve("qwen3.5:latest")
    end
  end

  describe "Context default find_model" do
    test "resolves a real Anthropic model without explicit injection" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert %Model{provider: :anthropic} = ctx.find_model.(:anthropic, "claude-haiku-4-5")
    end

    test "resolves Google via the registry now that CustomCompaction depends on it" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert %Model{provider: :google} = ctx.find_model.(:google, "gemini-2.5-flash")
    end

    test "still returns nil for unmodelled providers (no longer a hard nil stub)" do
      ctx = Context.new(%{cwd: "/tmp"})
      assert ctx.find_model.(:azure, "anything") == nil
    end
  end
end
