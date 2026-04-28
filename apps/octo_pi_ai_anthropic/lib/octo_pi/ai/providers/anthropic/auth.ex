defmodule OctoPi.AI.Providers.Anthropic.Auth do
  @moduledoc """
  Resolves Anthropic credentials for a request.

  Precedence:

    1. `opts.api_key` (explicit override; the name is historical —
       the value may be an OAuth token)
    2. `ANTHROPIC_OAUTH_TOKEN` env var
    3. `ANTHROPIC_API_KEY` env var
    4. Configured keychain reader (see `KeychainReader`; default noop)
    5. Raise

  OAuth tokens are detected by the `"sk-ant-oat"` substring; everything
  else is classified as an API key. The returned `Credentials` struct
  drives downstream request-shape choices (headers, identity system
  prompt, tool-name casing).

  Matches pi-mono semantics: `env-api-keys.ts` gives
  `ANTHROPIC_OAUTH_TOKEN` precedence over `ANTHROPIC_API_KEY`, and
  `anthropic.ts` L723-725 uses the same substring check.
  """

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Providers.Anthropic.Auth.Credentials

  @noop_reader OctoPi.AI.Providers.Anthropic.Auth.NoopKeychain

  @doc """
  Return a `Credentials` struct or raise if no source is available.
  """
  @spec resolve(CallOptions.t() | nil) :: Credentials.t()
  def resolve(opts \\ nil)
  def resolve(nil), do: resolve(%CallOptions{})

  def resolve(%CallOptions{api_key: key}) when is_binary(key) and key != "", do: classify(key, :opts)

  def resolve(%CallOptions{}) do
    with {:env_oauth, nil} <- {:env_oauth, get_env("ANTHROPIC_OAUTH_TOKEN")},
         {:env_api_key, nil} <- {:env_api_key, get_env("ANTHROPIC_API_KEY")},
         {:keychain, nil} <- {:keychain, keychain_reader().read()} do
      raise RuntimeError,
            "Anthropic credentials not available. Pass :api_key in CallOptions, " <>
              "export ANTHROPIC_OAUTH_TOKEN or ANTHROPIC_API_KEY, or log in to Claude Code."
    else
      {source, token} -> classify(token, source)
    end
  end

  @doc "True if the token looks like a Claude Code OAuth access token."
  @spec oauth?(binary()) :: boolean()
  def oauth?(token) when is_binary(token), do: String.contains?(token, "sk-ant-oat")

  @type source :: :opts | :env_oauth | :env_api_key | :keychain

  @spec classify(binary(), source()) :: Credentials.t()
  defp classify(token, source) do
    type = if oauth?(token), do: :oauth, else: :api_key

    :telemetry.execute(
      [:octo_pi_ai_anthropic, :auth, :resolved],
      %{},
      %{type: type, source: source}
    )

    %Credentials{type: type, token: token}
  end

  @spec get_env(binary()) :: binary() | nil
  defp get_env(name) do
    case System.get_env(name) do
      "" -> nil
      value -> value
    end
  end

  @spec keychain_reader() :: module()
  defp keychain_reader do
    Application.get_env(:octo_pi_ai_anthropic, :keychain_reader, @noop_reader)
  end
end
