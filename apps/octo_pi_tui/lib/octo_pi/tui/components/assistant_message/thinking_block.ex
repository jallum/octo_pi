defmodule OctoPi.TUI.Components.AssistantMessage.ThinkingBlock do
  @moduledoc """
  Transcript renderer adapter for `:thinking` content blocks.
  Wraps the source text with ANSI italic styling per line; cheap
  enough to render uncached, but the wrapping is still done in
  `to_iolist/1` so the Transcript-level cache benefits from
  finalize-time materialization.
  """

  @behaviour OctoPi.TUI.Transcript.Renderer

  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  defstruct [:snapshot, :theme, :width, :hide?, :hidden_label]

  @impl true
  def new(snapshot, %{theme: theme, width: width} = ctx) do
    %__MODULE__{
      snapshot: snapshot,
      theme: theme,
      width: width,
      hide?: Map.get(ctx, :hide_thinking, false),
      hidden_label: Map.get(ctx, :hidden_thinking_label, "Thinking...")
    }
  end

  @impl true
  def put(%__MODULE__{} = s, snapshot), do: %{s | snapshot: snapshot}

  @impl true
  def finalize(%__MODULE__{} = s, snapshot), do: %{s | snapshot: snapshot}

  @impl true
  def to_iolist(%__MODULE__{theme: theme, hide?: true, hidden_label: label}) do
    [" ", Theme.fg(theme, :thinking_text, Theme.italic(label))]
  end

  def to_iolist(%__MODULE__{snapshot: snapshot, theme: theme, width: width}) do
    text = String.trim(snapshot)

    if text == "" do
      []
    else
      content_width = max(1, (width || 80) - 1)

      text
      |> WrapAnsi.wrap(content_width)
      |> Enum.map(fn line -> " " <> Theme.fg(theme, :thinking_text, Theme.italic(line)) end)
      |> Enum.intersperse("\n")
    end
  end
end
