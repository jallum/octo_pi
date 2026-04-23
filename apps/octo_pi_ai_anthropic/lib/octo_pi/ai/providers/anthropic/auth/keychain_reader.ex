defmodule OctoPi.AI.Providers.Anthropic.Auth.KeychainReader do
  @moduledoc """
  Behaviour for reading a Claude Code OAuth access token from the
  host's credential store.

  Implementations return the access token binary, or `nil` if no
  credential is available. They **must not raise** — an unsupported
  platform or missing entry is `nil`, not an error. This is part of
  the contract; callers (e.g. `Auth.resolve/1`) rely on it.

  Installed via `Application.put_env(:octo_pi_ai_anthropic, :keychain_reader, MyModule)`.
  Default implementation: `OctoPi.AI.Providers.Anthropic.Auth.NoopKeychain` (always nil).
  """

  @callback read() :: String.t() | nil
end
