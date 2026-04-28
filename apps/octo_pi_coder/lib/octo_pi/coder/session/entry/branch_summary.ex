defmodule OctoPi.Coder.Session.Entry.BranchSummary do
  @moduledoc """
  Branch summary entry. Mirrors `BranchSummaryEntry` in
  `tmp/pi-mono/.../session-manager.ts:78-86`.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp fromId summary fromHook details)

  @enforce_keys [:id, :timestamp, :from_id, :summary]
  defstruct [
    :id,
    :parent_id,
    :timestamp,
    :from_id,
    :summary,
    :from_hook,
    :details,
    extras: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          from_id: String.t(),
          summary: String.t(),
          from_hook: boolean() | nil,
          details: term() | nil,
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "branch_summary"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"fromId", e.from_id},
      {"summary", e.summary}
    ]
    |> JSON.maybe_put("fromHook", e.from_hook)
    |> JSON.maybe_put("details", e.details)
    |> JSON.append_extras(e.extras)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "branch_summary"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      from_id: m["fromId"],
      summary: m["summary"],
      from_hook: m["fromHook"],
      details: m["details"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
