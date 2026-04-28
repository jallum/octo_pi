defmodule OctoPi.Coder.Session.Entry.Custom do
  @moduledoc """
  Custom entry — extension-specific persisted state, ignored by
  buildSessionContext. Mirrors `CustomEntry` in
  `tmp/pi-mono/.../session-manager.ts:98-102`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp customType data)

  @enforce_keys [:id, :timestamp, :custom_type]
  defstruct [:id, :parent_id, :timestamp, :custom_type, :data, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          custom_type: String.t(),
          data: term() | nil,
          extras: %{optional(String.t()) => term()}
        }

  @doc """
  Construct a fresh `Custom` entry with a generated 8-hex-char id and
  current ISO-8601 timestamp. Mirrors upstream `generateId` /
  `new Date().toISOString()` defaults so extensions don't have to
  hand-roll id generation when persisting state.
  """
  @spec new(String.t(), term()) :: t()
  def new(custom_type, data \\ nil) when is_binary(custom_type) do
    %__MODULE__{
      id: gen_id(),
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      custom_type: custom_type,
      data: data
    }
  end

  defp gen_id, do: 4 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

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
    |> JSON.append_extras(e.extras)
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
      data: m["data"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
