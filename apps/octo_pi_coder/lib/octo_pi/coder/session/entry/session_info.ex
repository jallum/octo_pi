defmodule OctoPi.Coder.Session.Entry.SessionInfo do
  @moduledoc """
  Session metadata entry — currently just an optional user-defined
  display name. Mirrors `SessionInfoEntry` in
  `tmp/pi-mono/.../session-manager.ts:112-115`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp name)

  @enforce_keys [:id, :timestamp]
  defstruct [:id, :parent_id, :timestamp, :name, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          name: String.t() | nil,
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "session_info"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp}
    ]
    |> JSON.maybe_put("name", e.name)
    |> JSON.append_extras(e.extras)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "session_info"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      name: m["name"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
