defmodule OctoPi.TUI.Components.TruncatedText do
  @moduledoc """
  Single-line text component that truncates to fit viewport width.
  Stops at the first newline — only the first logical line is
  rendered. Horizontal padding is applied on both sides; vertical
  padding adds blank (width-padded) lines above and below.

  Truncation uses ANSI/grapheme-aware `WrapAnsi.truncate_to_width/4`,
  bracketing the ellipsis with SGR resets so styled prefixes do not
  bleed into the trailing pad.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          text: String.t(),
          padding_x: non_neg_integer(),
          padding_y: non_neg_integer()
        }

  defstruct text: "", padding_x: 0, padding_y: 0

  @impl true
  def render(%__MODULE__{text: text, padding_x: px, padding_y: py}, width) do
    empty_line = String.duplicate(" ", width)
    available = max(1, width - px * 2)
    first_line = text |> String.split("\n", parts: 2) |> hd()
    display = WrapAnsi.truncate_to_width(first_line, available)

    pad = String.duplicate(" ", px)
    line_with_padding = pad <> display <> pad
    line_width = WrapAnsi.visible_width(line_with_padding)
    fill = String.duplicate(" ", max(0, width - line_width))
    content_line = line_with_padding <> fill

    List.duplicate(empty_line, py) ++ [content_line] ++ List.duplicate(empty_line, py)
  end

  @impl true
  @spec invalidate(t()) :: t()
  def invalidate(state), do: state
end
