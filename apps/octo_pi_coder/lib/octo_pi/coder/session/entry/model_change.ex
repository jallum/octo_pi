defmodule OctoPi.Coder.Session.Entry.ModelChange do
  @moduledoc """
  Model change entry. Mirrors `ModelChangeEntry` in
  `tmp/pi-mono/.../session-manager.ts:61-65`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp provider modelId)

  @enforce_keys [:id, :timestamp, :provider, :model_id]
  defstruct [:id, :parent_id, :timestamp, :provider, :model_id, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          provider: String.t(),
          model_id: String.t(),
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "model_change"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"provider", e.provider},
      {"modelId", e.model_id}
    ]
    |> JSON.append_extras(e.extras)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "model_change"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      provider: m["provider"],
      model_id: m["modelId"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
