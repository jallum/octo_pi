defmodule OctoPi.TUI.Components.UserMessage do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Theme

  @osc133_zone_start "\e]133;A\a"
  @osc133_zone_end "\e]133;B\a"
  @osc133_zone_final "\e]133;C\a"

  @type t :: %__MODULE__{
          text: String.t(),
          theme: Theme.t()
        }

  defstruct [:text, :theme]

  @spec new(String.t(), Theme.t()) :: t()
  def new(text, theme), do: %__MODULE__{text: text, theme: theme}

  @impl true
  def render(%__MODULE__{text: text}, _width) when text in ["", nil], do: []

  def render(%__MODULE__{text: text, theme: theme}, width) do
    if String.trim(text) == "" do
      []
    else
      do_render(text, theme, width)
    end
  end

  defp do_render(text, theme, width) do
    md = Markdown.new(text, theme, padding_x: 1)
    content_lines = Markdown.render(md, width)

    bg_fn = fn line -> Theme.bg(theme, :user_message_bg, pad_to_width(line, width)) end

    lines =
      [bg_fn.("") | Enum.map(content_lines, &bg_fn.(&1))] ++ [bg_fn.("")]

    wrap_osc133(lines)
  end

  defp pad_to_width(line, width) do
    visible_len = visible_length(line)
    if visible_len < width, do: line <> String.duplicate(" ", width - visible_len), else: line
  end

  defp visible_length(str) do
    str
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
  end

  defp wrap_osc133([single]) do
    [@osc133_zone_start <> single <> @osc133_zone_end <> @osc133_zone_final]
  end

  defp wrap_osc133([first | rest]) do
    {middle, [last]} = Enum.split(rest, -1)
    tagged_last = @osc133_zone_end <> @osc133_zone_final <> last
    [@osc133_zone_start <> first | middle] ++ [tagged_last]
  end
end
