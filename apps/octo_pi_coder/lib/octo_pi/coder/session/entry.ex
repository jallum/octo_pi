defmodule OctoPi.Coder.Session.Entry do
  @moduledoc """
  Tagged union of session-file body entries. Mirrors the `SessionEntry`
  union in `tmp/pi-mono/.../session-manager.ts:138-147` exactly: nine
  variants plus a `Passthrough` fallback so unrecognized `type` values
  still round-trip without code changes here.
  """

  alias OctoPi.Coder.Session.Entry.{
    BranchSummary,
    Compaction,
    Custom,
    CustomMessage,
    Label,
    Message,
    ModelChange,
    Passthrough,
    SessionInfo,
    ThinkingLevelChange
  }

  @type t ::
          Message.t()
          | Compaction.t()
          | BranchSummary.t()
          | ThinkingLevelChange.t()
          | ModelChange.t()
          | Label.t()
          | Custom.t()
          | CustomMessage.t()
          | SessionInfo.t()
          | Passthrough.t()

  @spec decode(map()) :: t()
  def decode(%{"type" => "message"} = m), do: Message.decode(m)
  def decode(%{"type" => "compaction"} = m), do: Compaction.decode(m)
  def decode(%{"type" => "branch_summary"} = m), do: BranchSummary.decode(m)
  def decode(%{"type" => "thinking_level_change"} = m), do: ThinkingLevelChange.decode(m)
  def decode(%{"type" => "model_change"} = m), do: ModelChange.decode(m)
  def decode(%{"type" => "label"} = m), do: Label.decode(m)
  def decode(%{"type" => "custom"} = m), do: Custom.decode(m)
  def decode(%{"type" => "custom_message"} = m), do: CustomMessage.decode(m)
  def decode(%{"type" => "session_info"} = m), do: SessionInfo.decode(m)
  def decode(%{"type" => _} = m), do: Passthrough.decode(m)

  @doc """
  Ordered key/value pairs for an entry, suitable for byte-stable
  JSONL emission via `SessionStore.append/2`. Mirrors per-entry
  `pairs/1` functions; centralized here for typed dispatch.
  """
  @spec pairs(t()) :: [{String.t(), term()}]
  def pairs(%Message{} = e), do: Message.pairs(e)
  def pairs(%Compaction{} = e), do: Compaction.pairs(e)
  def pairs(%BranchSummary{} = e), do: BranchSummary.pairs(e)
  def pairs(%ThinkingLevelChange{} = e), do: ThinkingLevelChange.pairs(e)
  def pairs(%ModelChange{} = e), do: ModelChange.pairs(e)
  def pairs(%Label{} = e), do: Label.pairs(e)
  def pairs(%Custom{} = e), do: Custom.pairs(e)
  def pairs(%CustomMessage{} = e), do: CustomMessage.pairs(e)
  def pairs(%SessionInfo{} = e), do: SessionInfo.pairs(e)
  def pairs(%Passthrough{raw: raw}), do: Enum.map(raw, fn {k, v} -> {to_string(k), v} end)

  @spec encode(t()) :: String.t()
  def encode(%Message{} = e), do: Message.encode(e)
  def encode(%Compaction{} = e), do: Compaction.encode(e)
  def encode(%BranchSummary{} = e), do: BranchSummary.encode(e)
  def encode(%ThinkingLevelChange{} = e), do: ThinkingLevelChange.encode(e)
  def encode(%ModelChange{} = e), do: ModelChange.encode(e)
  def encode(%Label{} = e), do: Label.encode(e)
  def encode(%Custom{} = e), do: Custom.encode(e)
  def encode(%CustomMessage{} = e), do: CustomMessage.encode(e)
  def encode(%SessionInfo{} = e), do: SessionInfo.encode(e)
  def encode(%Passthrough{} = e), do: Passthrough.encode(e)
end
