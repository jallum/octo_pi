defmodule OctoPi.Coder.Session.Entry do
  @moduledoc """
  Tagged union of session-file body entries. Mirrors the `SessionEntry`
  union in `tmp/pi-mono/.../session-manager.ts:138-147` (LabelEntry and
  CustomEntry included; CustomMessageEntry and SessionInfoEntry are
  out-of-scope for this ticket).

  `decode/1` dispatches on the `"type"` discriminator; unknown types
  fall through to `Passthrough` so future entry kinds round-trip safely
  without code changes here.
  """

  alias OctoPi.Coder.Session.Entry.{
    BranchSummary,
    Compaction,
    Custom,
    Label,
    Message,
    ModelChange,
    Passthrough,
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
          | Passthrough.t()

  @spec decode(map()) :: t()
  def decode(%{"type" => "message"} = m), do: Message.decode(m)
  def decode(%{"type" => "compaction"} = m), do: Compaction.decode(m)
  def decode(%{"type" => "branch_summary"} = m), do: BranchSummary.decode(m)
  def decode(%{"type" => "thinking_level_change"} = m), do: ThinkingLevelChange.decode(m)
  def decode(%{"type" => "model_change"} = m), do: ModelChange.decode(m)
  def decode(%{"type" => "label"} = m), do: Label.decode(m)
  def decode(%{"type" => "custom"} = m), do: Custom.decode(m)
  def decode(%{"type" => _} = m), do: Passthrough.decode(m)

  @spec encode(t()) :: String.t()
  def encode(%Message{} = e), do: Message.encode(e)
  def encode(%Compaction{} = e), do: Compaction.encode(e)
  def encode(%BranchSummary{} = e), do: BranchSummary.encode(e)
  def encode(%ThinkingLevelChange{} = e), do: ThinkingLevelChange.encode(e)
  def encode(%ModelChange{} = e), do: ModelChange.encode(e)
  def encode(%Label{} = e), do: Label.encode(e)
  def encode(%Custom{} = e), do: Custom.encode(e)
  def encode(%Passthrough{} = e), do: Passthrough.encode(e)
end
