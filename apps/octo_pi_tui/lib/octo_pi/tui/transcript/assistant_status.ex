defmodule OctoPi.TUI.Transcript.AssistantStatus do
  @moduledoc """
  Trailing entry for an assistant turn. Emits the OSC 133 zone end
  markers (when not a tool-use turn) plus any error/abort status
  line driven by the message's `stop_reason`.

  Only inserted on `MessageEnd` — successful `:stop` turns don't
  need a status line, but they still need the OSC 133 end markers.
  Tool-use turns (`has_tool_calls?: true`) skip both.
  """

  @behaviour OctoPi.TUI.Transcript.Renderer

  alias OctoPi.TUI.Theme

  @osc133_zone_end "\e]133;B\a"
  @osc133_zone_final "\e]133;C\a"

  defstruct stop_reason: nil,
            error_message: nil,
            has_tool_calls?: false,
            theme: nil

  @type t :: %__MODULE__{
          stop_reason: nil | atom(),
          error_message: String.t() | nil,
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

  # Convention: every renderer terminates its own lines. OSC 133
  # zone-end markers are zero-width and emitted inline (no terminator)
  # so they attach to the end of the previous entry's last line
  # rather than consuming their own row.
  @impl true
  def to_iolist(%__MODULE__{has_tool_calls?: true}), do: []

  def to_iolist(%__MODULE__{} = s) do
    [status_line(s), @osc133_zone_end, @osc133_zone_final]
  end

  defp status_line(%__MODULE__{stop_reason: :aborted, error_message: msg, theme: theme})
       when is_binary(msg) and msg != "Request was aborted",
       do: [Theme.fg(theme, :error, msg), "\n"]

  defp status_line(%__MODULE__{stop_reason: :aborted, theme: theme}),
    do: [Theme.fg(theme, :error, "Operation aborted"), "\n"]

  defp status_line(%__MODULE__{stop_reason: :error, error_message: msg, theme: theme}) do
    text = "Error: #{msg || "Unknown error"}"
    [Theme.fg(theme, :error, text), "\n"]
  end

  defp status_line(_), do: []
end
