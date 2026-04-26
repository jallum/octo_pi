defmodule OctoPi.Coder.Session.Entry.ModelChange do
  @moduledoc """
  Model change entry. Mirrors `ModelChangeEntry` in
  `tmp/pi-mono/.../session-manager.ts:61-65`.
  """

  alias OctoPi.Coder.Session.JSON

  @enforce_keys [:id, :timestamp, :provider, :model_id]
  defstruct [:id, :parent_id, :timestamp, :provider, :model_id]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          provider: String.t(),
          model_id: String.t()
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
      model_id: m["modelId"]
    }
  end
end
