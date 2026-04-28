defmodule OctoPi.Coder.Session.BranchSummaryMessage do
  @moduledoc """
  Synthetic LLM-context message produced when a `BranchSummaryEntry`
  appears on the current branch path. Mirrors `BranchSummaryMessage`
  in `tmp/pi-mono/.../core/messages.ts:55-60`.

  This struct is the *placement output* of `SessionManager.build_session_context/2`.
  Provider serialization lives in ticket E3 (opi-ixp.22) — see the
  E3 ticket comment to verify shape before serialization is added.
  """

  @role "branchSummary"

  @enforce_keys [:summary, :from_id, :timestamp]
  defstruct role: @role, summary: nil, from_id: nil, timestamp: 0

  @type t :: %__MODULE__{
          role: String.t(),
          summary: String.t(),
          from_id: String.t(),
          timestamp: integer()
        }

  @doc """
  Build a BranchSummaryMessage. Timestamp is normalized to ms-epoch.
  Mirrors `createBranchSummaryMessage` (`messages.ts:100-107`).
  """
  @spec new(String.t(), String.t(), String.t() | integer()) :: t()
  def new(summary, from_id, timestamp) do
    %__MODULE__{
      summary: summary,
      from_id: from_id,
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
