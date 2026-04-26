defmodule OctoPi.Coder.Session.Entry.Passthrough do
  @moduledoc """
  Forward-compat fallback for entries whose `type` discriminator is not
  one of the recognized variants. Stores the decoded JSON map verbatim
  so unknown entries survive a read/write round-trip without loss.
  """

  @enforce_keys [:raw]
  defstruct [:raw]

  @type t :: %__MODULE__{raw: map()}

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{raw: raw}), do: Jason.encode!(raw)

  @spec decode(map()) :: t()
  def decode(raw) when is_map(raw), do: %__MODULE__{raw: raw}
end
