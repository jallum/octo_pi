defmodule OctoPi.AI.Providers.Anthropic.Auth.NoopKeychain do
  @moduledoc """
  Default keychain reader: always returns `nil`. Swap in
  `OctoPi.AI.Providers.Anthropic.Auth.MacKeychain` (from opi-y1y.2)
  or a test double to change behaviour.
  """

  @behaviour OctoPi.AI.Providers.Anthropic.Auth.KeychainReader

  @impl true
  def read, do: nil
end
