defmodule OctoPi.TUI.Transcript.AssistantHeader do
  @moduledoc """
  Marker entry inserted at the start of an assistant turn. Carries
  no rendered output of its own; the Interactive render path uses
  these markers (paired with `AssistantStatus`) to demarcate turns
  for OSC 133 zone welding.

  `has_tool_calls?` is flipped via `Transcript.update/3` on
  `MessageEnd` so the post-processor can skip OSC injection on
  tool-use turns.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM

  defstruct msg_id: nil, has_tool_calls?: false

  @type t :: %__MODULE__{msg_id: String.t() | nil, has_tool_calls?: boolean()}

  @impl true
  def update(%__MODULE__{} = self, has_tool_calls?) when is_boolean(has_tool_calls?),
    do: %{self | has_tool_calls?: has_tool_calls?}

  @impl true
  def finalize(%__MODULE__{} = self, _), do: self

  @impl true
  def render(%__MODULE__{} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}, nil}
end
