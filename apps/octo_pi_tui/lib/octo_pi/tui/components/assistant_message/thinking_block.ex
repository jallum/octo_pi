defmodule OctoPi.TUI.Components.AssistantMessage.ThinkingBlock do
  @moduledoc """
  Streaming transcript entry for `:thinking` content blocks. Wraps
  the source text with ANSI italic styling per line; cheap enough
  to render uncached at the component level (the Transcript caches
  the resulting VNode).
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.WrapAnsi

  defstruct snapshot: ""

  @type t :: %__MODULE__{snapshot: binary()}

  @impl true
  def update(%__MODULE__{} = self, snapshot), do: %{self | snapshot: snapshot}

  @impl true
  def finalize(%__MODULE__{} = self, snapshot), do: %{self | snapshot: snapshot}

  @impl true
  def render(%__MODULE__{} = self, %RenderContext{hide_thinking: true} = ctx) do
    line = " " <> Theme.fg(ctx.theme, :thinking_text, Theme.italic(ctx.hidden_thinking_label))
    {self, %VDOM.VLines{lines: [line]}}
  end

  def render(%__MODULE__{snapshot: snapshot} = self, %RenderContext{theme: theme, width: width}) do
    text = String.trim(snapshot)

    lines =
      if text == "" do
        # Show placeholder when thinking block exists but has no content yet
        [" " <> Theme.fg(theme, :thinking_text, Theme.italic("Thinking…"))]
      else
        content_width = max(1, width - 1)

        text
        |> WrapAnsi.wrap(content_width)
        |> Enum.map(fn line -> " " <> Theme.fg(theme, :thinking_text, Theme.italic(line)) end)
      end

    {self, %VDOM.VLines{lines: lines}}
  end
end
