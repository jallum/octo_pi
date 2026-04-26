defmodule OctoPi.Coder.Session.Entry.Message do
  @moduledoc """
  Session entry wrapping an `AgentMessage`. Mirrors `SessionMessageEntry`
  in `tmp/pi-mono/.../session-manager.ts:51-54`.

  The `message` payload is held opaquely as a decoded JSON map for
  forward-compat; typed conversion to `OctoPi.Agent.Message.t()` happens
  at consumer boundaries.
  """

  alias OctoPi.Coder.Session.JSON

  @enforce_keys [:id, :timestamp, :message]
  defstruct [:id, :parent_id, :timestamp, :message]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          message: map()
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "message"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"message", e.message}
    ]
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "message"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      message: m["message"]
    }
  end
end
