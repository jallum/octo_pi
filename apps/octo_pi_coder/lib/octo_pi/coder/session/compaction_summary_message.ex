defmodule OctoPi.Coder.Session.CompactionSummaryMessage do
  @moduledoc """
  Synthetic LLM-context message representing a compaction boundary.
  Mirrors `CompactionSummaryMessage` in
  `tmp/pi-mono/.../core/messages.ts:62-67`.

  This struct is the *placement output* of `SessionManager.build_session_context/2`.
  Provider serialization (Anthropic + OpenAI wire format) lives in
  ticket E3 (opi-ixp.22) — when E3 lands, double-check this shape
  is what the providers want before adding serializers on top.
  """

  @role "compactionSummary"

  @enforce_keys [:summary, :tokens_before, :timestamp]
  defstruct role: @role, summary: nil, tokens_before: 0, timestamp: 0

  @type t :: %__MODULE__{
          role: String.t(),
          summary: String.t(),
          tokens_before: non_neg_integer(),
          timestamp: integer()
        }

  @doc """
  Build a CompactionSummaryMessage from a `summary` string, the
  pre-compaction token count, and an ISO-8601 timestamp string
  (which is converted to ms-epoch to match upstream).

  Mirrors `createCompactionSummaryMessage`
  (`messages.ts:109-120`).
  """
  @spec new(String.t(), non_neg_integer(), String.t() | integer()) :: t()
  def new(summary, tokens_before, timestamp) do
    %__MODULE__{
      summary: summary,
      tokens_before: tokens_before,
      timestamp: to_ms_epoch(timestamp)
    }
  end

  defp to_ms_epoch(ts) when is_integer(ts), do: ts

  defp to_ms_epoch(ts) when is_binary(ts) do
    case DateTime.from_iso8601(ts) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt, :millisecond)
      _ -> 0
    end
  end
end
