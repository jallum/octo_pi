defmodule OctoPi.Coder.Session.Entry.Compaction do
  @moduledoc """
  Compaction entry. Mirrors `CompactionEntry` in
  `tmp/pi-mono/.../session-manager.ts:67-76`.

  Optional `from_hook` and `details` are omitted from the wire when nil
  (matching JSON.stringify omitting `undefined`). Unknown wire keys are
  captured into `extras` for lossless round-trips.
  """

  alias OctoPi.Coder.Session.JSON

  @known_keys ~w(type id parentId timestamp summary firstKeptEntryId tokensBefore fromHook details)

  @enforce_keys [:id, :timestamp, :summary, :first_kept_entry_id, :tokens_before]
  defstruct [
    :id,
    :parent_id,
    :timestamp,
    :summary,
    :first_kept_entry_id,
    :tokens_before,
    :from_hook,
    :details,
    extras: %{}
  ]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          parent_id: String.t() | nil,
          timestamp: String.t() | nil,
          summary: String.t(),
          first_kept_entry_id: String.t(),
          tokens_before: non_neg_integer(),
          from_hook: boolean() | nil,
          details: term() | nil,
          extras: %{optional(String.t()) => term()}
        }

  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%__MODULE__{} = e) do
    [
      {"type", "compaction"},
      {"id", e.id},
      {"parentId", e.parent_id},
      {"timestamp", e.timestamp},
      {"summary", e.summary},
      {"firstKeptEntryId", e.first_kept_entry_id},
      {"tokensBefore", e.tokens_before}
    ]
    |> JSON.maybe_put("fromHook", e.from_hook)
    |> JSON.maybe_put("details", e.details)
    |> JSON.append_extras(e.extras)
  end

  @spec encode(t()) :: String.t()
  def encode(%__MODULE__{} = e), do: e |> pairs() |> JSON.object()

  @spec decode(map()) :: t()
  def decode(%{"type" => "compaction"} = m) do
    %__MODULE__{
      id: m["id"],
      parent_id: m["parentId"],
      timestamp: m["timestamp"],
      summary: m["summary"],
      first_kept_entry_id: m["firstKeptEntryId"],
      tokens_before: m["tokensBefore"],
      from_hook: m["fromHook"],
      details: m["details"],
      extras: JSON.extras(m, @known_keys)
    }
  end
end
