defmodule OctoPi.AI.Providers.Anthropic.Auth.Credentials do
  @moduledoc """
  Resolved credentials for a single Anthropic request.

  `type: :oauth` → Bearer-token flow with Claude-Code-specific headers,
  identity system prompt, and tool-name casing normalization. `:api_key`
  → the classic `x-api-key` shape.
  """

  @type auth_type :: :oauth | :api_key

  @enforce_keys [:type, :token]
  @type t :: %__MODULE__{
          type: auth_type(),
          token: String.t()
        }

  defstruct [:type, :token]
end
