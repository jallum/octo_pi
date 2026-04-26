defmodule OctoPi.Coder.Session.Entry.Label do
  @moduledoc """
  Label entry — user-defined bookmark on another entry. A nil `label`
  acts as a deletion marker. Mirrors `LabelEntry` in
  `tmp/pi-mono/.../session-manager.ts:104-109`.
  """

  alias OctoPi.Coder.Session.JSON

  @enforce_keys [:id, :timestamp, :target_id]
  defstruct [:id, :parent_id, :timestamp, :target_id, :label]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          target_id: String.t(),
          label: String.t() | nil
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "label"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"targetId", e.target_id},
      {"label", e.label}
    ]
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "label"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      target_id: m["targetId"],
      label: m["label"]
    }
  end
end
