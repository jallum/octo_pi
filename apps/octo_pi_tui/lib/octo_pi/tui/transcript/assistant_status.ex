defmodule OctoPi.TUI.Transcript.AssistantStatus do
  @moduledoc """
  Trailing entry inserted at the end of an assistant turn. Renders
  an optional error/abort status line driven by `stop_reason`, and
  serves as the closing marker for OSC 133 injection in the
  Interactive render path.

  Successful `:stop` turns and tool-use turns emit no lines; the
  entry still serves as a turn-end marker.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  defstruct stop_reason: nil,
            error_message: nil,
            has_tool_calls?: false

  @type t :: %__MODULE__{
          stop_reason: nil | atom(),
          error_message: String.t() | nil,
          has_tool_calls?: boolean()
        }

  @impl true
  def render(%__MODULE__{} = self, %RenderContext{theme: theme}),
    do: {self, %VDOM.VLines{lines: status_lines(self, theme)}}

  defp status_lines(%__MODULE__{stop_reason: nil}, _theme), do: []
  defp status_lines(%__MODULE__{has_tool_calls?: true}, _theme), do: []

  defp status_lines(%__MODULE__{stop_reason: :aborted, error_message: msg}, theme)
       when is_binary(msg) and msg != "Request was aborted", do: [Theme.fg(theme, :error, msg)]

  defp status_lines(%__MODULE__{stop_reason: :aborted}, theme), do: [Theme.fg(theme, :error, "Operation aborted")]

  defp status_lines(%__MODULE__{stop_reason: :error, error_message: msg}, theme),
    do: [Theme.fg(theme, :error, "Error: #{msg || "Unknown error"}")]

  defp status_lines(%__MODULE__{}, _theme), do: []
end
