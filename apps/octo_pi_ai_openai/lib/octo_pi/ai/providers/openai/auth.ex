defmodule OctoPi.AI.Providers.OpenAI.Auth do
  @moduledoc """
  Resolves an API key for OpenAI-completions-dialect providers
  (OpenAI, OpenRouter, xAI, Groq, DeepSeek, etc.).

  Priority: explicit `StreamOptions.api_key` → provider-specific
  env var. Returns `nil` when neither is set, which is the correct
  outcome for keyless backends like a local Ollama server.

  Mirrors pi-mono's `env-api-keys.ts` `getEnvApiKey/1`.
  """

  alias OctoPi.AI.{Model, StreamOptions}

  @env_by_provider %{
    openai: "OPENAI_API_KEY",
    openrouter: "OPENROUTER_API_KEY",
    xai: "XAI_API_KEY",
    groq: "GROQ_API_KEY",
    cerebras: "CEREBRAS_API_KEY",
    deepseek: "DEEPSEEK_API_KEY",
    fireworks: "FIREWORKS_API_KEY",
    mistral: "MISTRAL_API_KEY",
    huggingface: "HF_TOKEN",
    minimax: "MINIMAX_API_KEY",
    zai: "ZAI_API_KEY",
    vercel_ai_gateway: "AI_GATEWAY_API_KEY"
  }

  @spec resolve(Model.t(), StreamOptions.t()) :: binary() | nil
  def resolve(_model, %StreamOptions{api_key: key}) when is_binary(key) and key != "", do: key
  def resolve(%Model{provider: provider}, _opts), do: provider |> env_var() |> read_env()

  defp env_var(provider), do: Map.get(@env_by_provider, provider)

  defp read_env(nil), do: nil
  defp read_env(var), do: var |> System.get_env() |> blank_to_nil()

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v
end
