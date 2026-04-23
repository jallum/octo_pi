defmodule OctoPi.AI.Providers.Anthropic.Auth.KeychainReader do
  @moduledoc """
  Behaviour for reading a Claude Code OAuth access token from the
  host's credential store.

  Implementations return the access token binary, or `nil` if no
  credential is available. They must not raise — an unsupported
  platform or missing entry is `nil`, not an error.

  Installed via `Application.put_env(:octo_pi_ai, :anthropic_keychain_reader, MyModule)`.
  Default implementation: `OctoPi.AI.Providers.Anthropic.Auth.NoopKeychain` (always nil).
  """

  @callback read() :: String.t() | nil

  @doc "Invoke the configured reader, guarding against crashes."
  @spec read(module()) :: String.t() | nil
  def read(module) do
    module.read()
  rescue
    _ -> nil
  end
end
