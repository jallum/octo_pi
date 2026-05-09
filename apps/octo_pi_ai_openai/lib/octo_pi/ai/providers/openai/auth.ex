defmodule OctoPi.AI.Providers.OpenAI.Auth do
  @moduledoc """
  Resolves an API key for OpenAI-completions-dialect providers
  (OpenAI, OpenRouter, xAI, Groq, DeepSeek, etc.).

  Priority: explicit `CallOptions.api_key` → runner env var → auth.json fallback.
  Returns `nil` when neither is set, which is the correct outcome for
  keyless backends like a local Ollama server.

  Mirrors pi-mono's `env-api-keys.ts` `getEnvApiKey/1`.
  """

  alias OctoPi.AI.{CallOptions, Model}

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

  @spec resolve(Model.t(), CallOptions.t()) :: binary() | nil
  def resolve(_model, %CallOptions{api_key: key}) when is_binary(key) and key != "", do: key

  def resolve(%Model{provider: provider}, _opts) do
    # 1. Try environment variable first (runner auth spec)
    env_key = env_var_name(provider)
    with nil <- read_env(env_key) do
      # 2. Fall back to auth.json
      auth_file_key(provider) |> read_auth_file() |> auth_file_to_key()
    end
  end

  defp env_var_name(provider), do: Map.get(@env_by_provider, provider)

  defp read_env(nil), do: nil
  defp read_env(var), do: var |> System.get_env() |> blank_to_nil()

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v), do: v

  # Map provider atom to the key used in auth.json
  defp auth_file_key(:openrouter), do: "openrouter"
  defp auth_file_key(provider), do: to_string(provider)

  # Read API key from ~/.octo_pi/auth.json (path overridable via app env for tests)
  defp read_auth_file(provider_key) do
    auth_file =
      Application.get_env(:octo_pi_ai_openai, :auth_file, Path.expand("~/.octo_pi/auth.json"))

    case File.read(auth_file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> Map.get(map, provider_key)
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Convert auth.json value to key string
  defp auth_file_to_key(%{"literal" => key}) when is_binary(key), do: key
  defp auth_file_to_key(%{"env" => var}) when is_binary(var), do: read_env(var)
  defp auth_file_to_key(%{"cmd" => cmd}) do
    {out, 0} = System.shell(cmd, stderr_to_stdout: true)
    String.trim(out)
  end
  defp auth_file_to_key(_), do: nil
end
