defmodule OctoPi.Coder.Session.Entry.CustomMessage do
  @moduledoc """
  Custom-message entry — extension-injected content that DOES
  participate in LLM context (unlike `CustomEntry` which is invisible
  to the model). Mirrors `CustomMessageEntry` in
  `tmp/pi-mono/.../session-manager.ts:129-135`.

  `content` is either a plain string or a list of decoded text/image
  blocks held opaquely as JSON-shaped maps for forward-compat. Typed
  conversion happens at consumer boundaries.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp customType content details display)

  @enforce_keys [:id, :timestamp, :custom_type, :content, :display]
  defstruct [
    :id,
    :parent_id,
    :timestamp,
    :custom_type,
    :content,
    :details,
    :display,
    extras: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          parent_id: String.t() | nil,
          timestamp: String.t(),
          custom_type: String.t(),
          content: String.t() | [map()],
          details: term() | nil,
          display: boolean(),
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "custom_message"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"customType", e.custom_type},
      {"content", e.content},
      {"display", e.display}
    ]
    |> JSON.maybe_put("details", e.details)
    |> JSON.append_extras(e.extras)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "custom_message"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      custom_type: m["customType"],
      content: m["content"],
      details: m["details"],
      display: m["display"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
