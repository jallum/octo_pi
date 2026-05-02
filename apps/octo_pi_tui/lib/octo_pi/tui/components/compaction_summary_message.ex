defmodule OctoPi.TUI.Components.CompactionSummaryMessage do
  @moduledoc """
  TUI component for a compaction summary boundary. Port of
  `tmp/pi-mono/.../components/compaction-summary-message.ts`.

  Renders a `[compaction]` label followed by:
    * Collapsed — "Compacted from X tokens (<key> to expand)"
    * Expanded  — full summary as Markdown with a bold header

  Uses `custom_message_bg` / `custom_message_label` / `custom_message_text`
  theme colors, matching upstream visual style.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.Coder.Session.CompactionSummaryMessage, as: Msg
  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @expand_action "app.tools.expand"

  @type t :: %__MODULE__{
          message: Msg.t(),
          keybindings: Keybindings.t(),
          expanded: boolean()
        }

  defstruct [:message, :keybindings, expanded: false]

  @spec new(Msg.t(), keyword()) :: t()
  def new(%Msg{} = message, opts \\ []) do
    kb = Keyword.get(opts, :keybindings, Keybindings.new())
    %__MODULE__{message: message, keybindings: kb}
  end

  @spec toggle_expanded(t()) :: t()
  def toggle_expanded(%__MODULE__{expanded: e} = comp), do: %{comp | expanded: !e}

  @impl true
  def render(%__MODULE__{} = comp, %RenderContext{theme: theme, width: width}),
    do: {comp, %VDOM.VLines{lines: do_render(comp, theme, width)}, nil}

  @impl true
  def handle_key(%__MODULE__{} = comp, key) do
    expand_keys = Keybindings.get_keys(comp.keybindings, @expand_action)

    if key.key in expand_keys do
      toggle_expanded(comp)
    else
      comp
    end
  end

  # ── private ──────────────────────────────────────────────────────────────

  defp do_render(%__MODULE__{message: msg, expanded: expanded, keybindings: kb}, theme, width) do
    label = Theme.fg(theme, :custom_message_label, Theme.bold("[compaction]"))
    token_str = format_number(msg.tokens_before)

    content_child =
      if expanded do
        header = "**Compacted from #{token_str} tokens**\n\n"
        Markdown.new(header <> msg.summary, theme, padding_x: 0)
      else
        expand_key =
          kb |> Keybindings.get_keys(@expand_action) |> List.first("ctrl+o")

        text =
          Theme.fg(theme, :custom_message_text, "Compacted from #{token_str} tokens (") <>
            Theme.fg(theme, :dim, expand_key) <>
            Theme.fg(theme, :custom_message_text, " to expand)")

        %Text{content: text}
      end

    bg_fn = fn text -> Theme.bg(theme, :custom_message_bg, text) end

    box =
      [border: false, padding_x: 1, bg_fn: bg_fn]
      |> Box.new()
      |> Box.add_child(%Text{content: label})
      |> Box.add_child(%Text{content: ""})
      |> Box.add_child(content_child)

    ["" | Box.render(box, width)]
  end

  defp format_number(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end
end
