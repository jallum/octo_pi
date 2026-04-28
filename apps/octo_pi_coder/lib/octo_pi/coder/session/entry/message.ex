defmodule OctoPi.Coder.Session.Entry.Message do
  @moduledoc """
  Session entry wrapping an `AgentMessage`. Mirrors `SessionMessageEntry`
  in `tmp/pi-mono/.../session-manager.ts:51-54`.

  The `message` payload is held opaquely as a decoded JSON map for
  forward-compat; typed conversion to `OctoPi.Agent.Message.t()` happens
  at consumer boundaries. Unknown wire keys are preserved in `extras`
  so round-trips stay lossless.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp message)

  @enforce_keys [:id, :timestamp, :message]
  defstruct [:id, :parent_id, :timestamp, :message, extras: %{}]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          message: map(),
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    JSON.append_extras(
      [
        {"type", "message"},
        {"id", e.id},
        {"parentId", e.parent_id},
        {"timestamp", e.timestamp},
        {"message", e.message}
      ],
      e.extras
    )
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "message"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      message: m["message"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
