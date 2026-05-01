defmodule OctoPi.TUI.Transcript.AssistantHeader do
  @moduledoc """
  Top-level Transcript entry that opens an assistant turn. Emits a
  leading blank line and the OSC 133 zone start marker (when the
  turn isn't a pure tool-use turn — those skip the markers entirely
  to match upstream pi-mono behavior).

  Carries `msg_id` for correlation with `AssistantStatus` and the
  block entries that follow it in Transcript order.
  """

  @behaviour OctoPi.TUI.Transcript.Renderer

  alias OctoPi.TUI.Theme

  @osc133_zone_start "\e]133;A\a"

  defstruct msg_id: nil, has_tool_calls?: false, theme: nil

  @type t :: %__MODULE__{
          msg_id: String.t() | nil,
          has_tool_calls?: boolean(),
          theme: Theme.t() | nil
        }

  @impl true
  def new(%__MODULE__{} = entry, %{theme: theme}), do: %{entry | theme: theme}
  def new(entry, _ctx), do: entry

  @impl true
  def put(%__MODULE__{} = s, %__MODULE__{} = entry), do: %{entry | theme: s.theme}

  @impl true
  def finalize(%__MODULE__{} = s, %__MODULE__{} = entry), do: %{entry | theme: s.theme}

  # The OSC 133 zone-start marker is zero-width side-channel — emit
  # it inline (no terminator) so it attaches to the start of the
  # next entry's first line rather than consuming its own row. The
  # vertical gap before the assistant zone is owned by the previous
  # entry (UserMessage's own bottom-of-bubble blank), so we don't
  # add one here.
  @impl true
  def to_iolist(%__MODULE__{has_tool_calls?: true}), do: []
  def to_iolist(%__MODULE__{}), do: [@osc133_zone_start]
end
