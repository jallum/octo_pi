defmodule OctoPi.TUI.Components.Box do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          children: [struct()],
          border: boolean(),
          rounded: boolean(),
          title: String.t() | nil,
          padding_x: non_neg_integer(),
          padding_y: non_neg_integer(),
          bg_fn: (String.t() -> String.t()) | nil,
          border_color: (String.t() -> String.t()) | nil
        }

  defstruct children: [],
            border: false,
            rounded: false,
            title: nil,
            padding_x: 1,
            padding_y: 0,
            bg_fn: nil,
            border_color: nil

  @spec new(keyword()) :: t()
  def new(opts \\ []), do: struct!(__MODULE__, opts)

  @spec add_child(t(), struct()) :: t()
  def add_child(%__MODULE__{children: children} = box, child) do
    %{box | children: children ++ [child]}
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = box), do: %{box | children: []}

  @impl true
  def render(%__MODULE__{children: []}, _width), do: []

  def render(%__MODULE__{border: true} = box, width) do
    render_bordered(box, width)
  end

  def render(%__MODULE__{} = box, width) do
    render_borderless(box, width)
  end

  defp render_bordered(box, width) do
    content_width = max(1, width - 2 - box.padding_x * 2)
    child_lines = render_children(box.children, content_width)

    if child_lines == [] do
      []
    else
      pad = String.duplicate(" ", box.padding_x)
      color = box.border_color || (&Function.identity/1)

      top = build_top_border(box, width, color)
      bottom = build_bottom_border(box, width, color)

      content =
        Enum.map(child_lines, fn line ->
          right_pad = max(0, width - 2 - box.padding_x * 2 - WrapAnsi.visible_width(line))
          inner = pad <> line <> String.duplicate(" ", right_pad) <> pad
          color.("│") <> apply_bg(inner, box.bg_fn) <> color.("│")
        end)

      pad_lines = build_padding_lines(box, width, color)

      [top] ++ pad_lines ++ content ++ pad_lines ++ [bottom]
    end
  end

  defp render_borderless(box, width) do
    content_width = max(1, width - box.padding_x * 2)
    child_lines = render_children(box.children, content_width)

    if child_lines == [] do
      []
    else
      pad = String.duplicate(" ", box.padding_x)

      content =
        Enum.map(child_lines, fn line ->
          right_pad = max(0, content_width - WrapAnsi.visible_width(line))
          inner = pad <> line <> String.duplicate(" ", right_pad) <> pad
          apply_bg(inner, box.bg_fn)
        end)

      pad_lines =
        if box.padding_y > 0 do
          full = String.duplicate(" ", width)
          List.duplicate(apply_bg(full, box.bg_fn), box.padding_y)
        else
          []
        end

      pad_lines ++ content ++ pad_lines
    end
  end

  defp build_top_border(box, width, color) do
    {tl, tr} = if box.rounded, do: {"╭", "╮"}, else: {"┌", "┐"}
    inner_width = max(0, width - 2)

    bar =
      case box.title do
        nil ->
          String.duplicate("─", inner_width)

        title ->
          title_w = WrapAnsi.visible_width(title)
          remaining = max(0, inner_width - title_w - 2)
          " " <> title <> " " <> String.duplicate("─", remaining)
      end

    color.(tl <> bar <> tr)
  end

  defp build_bottom_border(box, width, color) do
    {bl, br} = if box.rounded, do: {"╰", "╯"}, else: {"└", "┘"}
    inner_width = max(0, width - 2)
    color.(bl <> String.duplicate("─", inner_width) <> br)
  end

  defp build_padding_lines(box, width, color) do
    if box.padding_y > 0 do
      inner = String.duplicate(" ", max(0, width - 2))
      line = color.("│") <> apply_bg(inner, box.bg_fn) <> color.("│")
      List.duplicate(line, box.padding_y)
    else
      []
    end
  end

  defp render_children(children, width) do
    Enum.flat_map(children, fn %mod{} = child -> mod.render(child, width) end)
  end

  defp apply_bg(text, nil), do: text
  defp apply_bg(text, bg_fn), do: bg_fn.(text)
end
