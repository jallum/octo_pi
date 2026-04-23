defmodule OctoPi.AI.Providers.Anthropic.Auth.MacKeychain do
  @moduledoc """
  Reads the Claude Code OAuth access token from the macOS login
  keychain.

  Looks up the generic-password entry named `"Claude Code-credentials"`
  owned by the current user. The entry's value is a JSON document
  Claude Code writes on login; we extract `claudeAiOauth.accessToken`.

  Returns `nil` on any failure path:
    - Not running on macOS
    - `security` command missing from PATH
    - Entry not found (exit status 44 from `security`)
    - JSON can't be decoded
    - Required keys missing

  Never raises, never prompts the user beyond the one-time access
  approval macOS itself manages — matches what the Claude Code CLI
  does, which is the whole point: if you're already logged into
  Claude Code, octo_pi_ai picks up the same token without asking for
  anything.

  To wire this in as the default reader for the app:

      # config/runtime.exs
      import Config
      if :os.type() == {:unix, :darwin} do
        config :octo_pi_ai,
          keychain_reader:
            OctoPi.AI.Providers.Anthropic.Auth.MacKeychain
      end

  Tests that don't want to touch the real keychain should override
  back to `NoopKeychain` in `setup`.
  """

  @behaviour OctoPi.AI.Providers.Anthropic.Auth.KeychainReader

  @service "Claude Code-credentials"

  @impl true
  def read do
    with true <- macos?(),
         {:ok, user} <- current_user(),
         {:ok, json} <- run_security(user),
         {:ok, token} <- parse_token(json) do
      token
    else
      _ -> nil
    end
  end

  @doc """
  Extract the Claude Code OAuth access token from the JSON blob
  `security(1)` writes out. Exposed for testing.
  """
  @spec parse_token(binary()) :: {:ok, String.t()} | :error
  def parse_token(json) when is_binary(json) do
    with {:ok, parsed} <- Jason.decode(json),
         token when is_binary(token) <- get_in(parsed, ["claudeAiOauth", "accessToken"]) do
      {:ok, token}
    else
      _ -> :error
    end
  end

  defp macos?, do: :os.type() == {:unix, :darwin}

  defp current_user do
    case System.get_env("USER") do
      user when is_binary(user) and user != "" -> {:ok, user}
      _ -> :error
    end
  end

  defp run_security(user) do
    {output, status} =
      System.cmd(
        "security",
        ["find-generic-password", "-a", user, "-s", @service, "-w"],
        stderr_to_stdout: true
      )

    case status do
      0 -> {:ok, String.trim(output)}
      _ -> :error
    end
  rescue
    # ErlangError on missing binary, etc.
    _ -> :error
  end
end
