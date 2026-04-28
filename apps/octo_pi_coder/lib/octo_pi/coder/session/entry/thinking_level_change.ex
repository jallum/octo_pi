defmodule OctoPi.Coder.Session.Entry.ThinkingLevelChange do
  @moduledoc """
  Thinking-level change entry. Mirrors `ThinkingLevelChangeEntry` in
  `tmp/pi-mono/.../session-manager.ts:56-59`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp thinkingLevel)

  @enforce_keys [:id, :timestamp, :thinking_level]
  defstruct [:id, :parent_id, :timestamp, :thinking_level, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          thinking_level: String.t(),
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    JSON.append_extras(
      [
        {"type", "thinking_level_change"},
        {"id", e.id},
        {"parentId", e.parent_id},
        {"timestamp", e.timestamp},
        {"thinkingLevel", e.thinking_level}
      ],
      e.extras
    )
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "thinking_level_change"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      thinking_level: m["thinkingLevel"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
