defmodule OctoPi.Coder.Session.Entry.Label do
  @moduledoc """
  Label entry — user-defined bookmark on another entry. A nil `label`
  acts as a deletion marker. Mirrors `LabelEntry` in
  `tmp/pi-mono/.../session-manager.ts:104-109`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp targetId label)

  @enforce_keys [:id, :timestamp, :target_id]
  defstruct [:id, :parent_id, :timestamp, :target_id, :label, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          target_id: String.t(),
          label: String.t() | nil,
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    JSON.append_extras(
      [
        {"type", "label"},
        {"id", e.id},
        {"parentId", e.parent_id},
        {"timestamp", e.timestamp},
        {"targetId", e.target_id},
        {"label", e.label}
      ],
      e.extras
    )
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
      label: m["label"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
