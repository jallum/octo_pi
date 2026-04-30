defmodule OctoPi.TUI.Transcript.ComponentWrapper do
  @moduledoc """
  Generic Transcript renderer adapter for any struct that implements
  `OctoPi.TUI.Component`. Calls the component's `render(state, width)`
  on `to_iolist/1` and intersperses newlines.

  Used for entry kinds whose own struct already produces
  `[String.t()]` lines and doesn't have a more incremental story —
  UserMessage, ToolExecution, BashExecution, CompactionSummaryMessage,
  the existing `AssistantMessage` (during transition). Per-render cost
  is one full `Component.render`; the win comes from `Transcript`
  caching the result in `rendered` after the first call.
  """

  @behaviour OctoPi.TUI.Transcript.Renderer

  defstruct [:entry, :width]

  @impl true
  def new(entry, %{width: width}) when is_integer(width), do: %__MODULE__{entry: entry, width: width}
  def new(entry, _ctx), do: %__MODULE__{entry: entry, width: nil}

  @impl true
  def put(%__MODULE__{} = s, entry), do: %{s | entry: entry}

  @impl true
  def finalize(%__MODULE__{} = s, entry), do: %{s | entry: entry}

  @impl true
  def to_iolist(%__MODULE__{entry: entry, width: width}) when is_integer(width) do
    case render(entry, width) do
      [] -> []
      lines -> Enum.intersperse(lines, "\n")
    end
  end

  def to_iolist(%__MODULE__{}), do: []

  defp render(entry, width) do
    mod = entry.__struct__
    mod.render(entry, width)
  end
end
