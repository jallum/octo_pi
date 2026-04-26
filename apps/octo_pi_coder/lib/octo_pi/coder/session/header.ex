defmodule OctoPi.Coder.Session.Header do
  @moduledoc """
  v3 session header — the first JSONL line in every session file.

  Mirrors `SessionHeader` in
  `tmp/pi-mono/packages/coding-agent/src/core/session-manager.ts:30-37`.
  Encoded key order matches upstream byte-for-byte: type, version, id,
  timestamp, cwd, parentSession.
  """

  alias OctoPi.Coder.Session.JSON

  @enforce_keys [:id, :timestamp, :cwd]
  defstruct [:id, :version, :timestamp, :cwd, :parent_session]

  @type t :: %__MODULE__{
          id: String.t(),
          version: integer() | nil,
          timestamp: String.t(),
          cwd: String.t(),
          parent_session: String.t() | nil
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = h) do
    [
      {"type", "session"},
      {"version", h.version},
      {"id", h.id},
      {"timestamp", h.timestamp},
      {"cwd", h.cwd},
      {"parentSession", h.parent_session}
    ]
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = h), do: h |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "session"} = m) do
    %__MODULE__{
      version: m["version"],
      id: m["id"],
      timestamp: m["timestamp"],
      cwd: m["cwd"],
      parent_session: m["parentSession"]
    }
  end
end
