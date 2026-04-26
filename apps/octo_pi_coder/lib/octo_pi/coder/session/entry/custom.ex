defmodule OctoPi.Coder.Session.Entry.Custom do
  @moduledoc """
  Custom entry — extension-specific persisted state, ignored by
  buildSessionContext. Mirrors `CustomEntry` in
  `tmp/pi-mono/.../session-manager.ts:98-102`.
  """

  alias OctoPi.Coder.Session.JSON

  @enforce_keys [:id, :timestamp, :custom_type]
  defstruct [:id, :parent_id, :timestamp, :custom_type, :data]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          custom_type: String.t(),
          data: term() | nil
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "custom"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"customType", e.custom_type}
    ]
    |> JSON.maybe_put("data", e.data)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "custom"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      custom_type: m["customType"],
      data: m["data"]
    }
  end
end
