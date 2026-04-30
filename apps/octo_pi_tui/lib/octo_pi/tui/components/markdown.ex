defmodule OctoPi.TUI.Components.Markdown do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown.Lexer
  alias OctoPi.TUI.SyntaxHighlight
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          text: String.t(),
          theme: Theme.t(),
          padding_x: non_neg_integer(),
          padding_y: non_neg_integer()
        }

  defstruct [:text, :theme, padding_x: 0, padding_y: 0]

  @spec new(String.t(), Theme.t(), keyword()) :: t()
  def new(text, theme, opts \\ []) do
    %__MODULE__{
      text: text,
      theme: theme,
      padding_x: Keyword.get(opts, :padding_x, 0),
      padding_y: Keyword.get(opts, :padding_y, 0)
    }
  end

  @impl true
  def render(%__MODULE__{text: text}, _width) when text in ["", nil], do: []

  def render(%__MODULE__{text: text} = md, width) do
    if String.trim(text) == "" do
      []
    else
      do_render(md, width)
    end
  end

  defp do_render(%__MODULE__{text: text, theme: theme, padding_x: px, padding_y: py}, width) do
    content_width = max(1, width - px * 2)
    normalized = String.replace(text, "\t", "   ")
    ast = Lexer.tokenize(normalized)

    lines = render_blocks(ast, content_width, theme)
    lines = clamp_width(lines, content_width)

    lines = apply_padding_x(lines, px)
    lines = apply_padding_y(lines, py)
    lines
  end

  # ── Block rendering ────────────────────────────────────────────

  defp render_blocks(blocks, width, theme) do
    blocks
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      next = Enum.at(blocks, idx + 1)
      render_block(block, width, theme, next)
    end)
  end

  defp render_block({:heading, 1, children}, _width, theme, next) do
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(Theme.underline(text)))
    maybe_space([styled], next)
  end

  defp render_block({:heading, 2, children}, _width, theme, next) do
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(text))
    maybe_space([styled], next)
  end

  defp render_block({:heading, level, children}, _width, theme, next) when level in 3..6 do
    prefix = String.duplicate("#", level) <> " "
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(prefix <> text))
    maybe_space([styled], next)
  end

  defp render_block({:paragraph, children}, width, theme, next) do
    text = render_inline(children, theme)
    lines = WrapAnsi.wrap(text, width)
    maybe_space(lines, next)
  end

  defp render_block({:code_block, lang, code}, _width, theme, next) do
    label = "```#{lang || ""}"

    code_lines =
      if lang && SyntaxHighlight.supported?(lang) do
        SyntaxHighlight.highlight(code, lang, theme)
      else
        code |> String.split("\n") |> Enum.map(&Theme.fg(theme, :md_code_block, &1))
      end

    lines = [
      Theme.fg(theme, :md_code_block_border, label)
      | Enum.map(code_lines, &("  " <> &1))
    ]

    lines = lines ++ [Theme.fg(theme, :md_code_block_border, "```")]
    maybe_space(lines, next)
  end

  defp render_block({:blockquote, blocks}, width, theme, next) do
    quote_width = max(1, width - 2)
    inner_lines = render_blocks(blocks, quote_width, theme)
    inner_lines = Enum.reverse(drop_trailing_empty(Enum.reverse(inner_lines)))

    lines =
      Enum.map(inner_lines, fn line ->
        styled = Theme.fg(theme, :md_quote, Theme.italic(line))
        Theme.fg(theme, :md_quote_border, "│ ") <> styled
      end)

    maybe_space(lines, next)
  end

  defp render_block({:list, kind, items}, _width, theme, _next) do
    render_list_items(items, theme, kind, 0)
  end

  defp render_block(:hr, width, theme, next) do
    line = Theme.fg(theme, :md_hr, String.duplicate("─", min(width, 80)))
    maybe_space([line], next)
  end

  defp render_block({:table, headers, rows}, width, theme, next) do
    header_strings = Enum.map(headers, &render_inline(&1, theme))
    row_strings = Enum.map(rows, fn row -> Enum.map(row, &render_inline(&1, theme)) end)
    lines = render_table(header_strings, row_strings, width, theme)
    maybe_space(lines, next)
  end

  defp render_block(_block, _width, _theme, _next), do: []

  # ── Inline rendering ───────────────────────────────────────────

  defp render_inline(children, theme) do
    Enum.map_join(children, "", &render_inline_node(&1, theme))
  end

  defp render_inline_node(text, _theme) when is_binary(text), do: text

  defp render_inline_node({:strong, children}, theme) do
    Theme.bold(render_inline(children, theme))
  end

  defp render_inline_node({:em, children}, theme) do
    Theme.italic(render_inline(children, theme))
  end

  defp render_inline_node({:code, text}, theme) do
    Theme.fg(theme, :md_code, text)
  end

  defp render_inline_node({:del, children}, theme) do
    Theme.strikethrough(render_inline(children, theme))
  end

  defp render_inline_node({:link, href, children}, theme) do
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_link, Theme.underline(text))

    if href && text != href do
      styled <> Theme.fg(theme, :md_link_url, " (#{href})")
    else
      styled
    end
  end

  # ── Lists ───────────────────────────────────────────────────────

  defp render_list_items(items, theme, kind, depth) do
    indent = String.duplicate("  ", depth)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {{:li, inline, nested}, idx} ->
      bullet = format_bullet(kind, idx)
      styled_bullet = Theme.fg(theme, :md_list_bullet, bullet)
      text = render_inline(inline, theme)

      first_line = indent <> styled_bullet <> text

      nested_lines =
        Enum.flat_map(nested, fn
          {:list, sub_kind, sub_items} ->
            render_list_items(sub_items, theme, sub_kind, depth + 1)

          block ->
            render_block(block, 80, theme, nil)
        end)

      [first_line | nested_lines]
    end)
  end

  defp format_bullet(:ul, _idx), do: "- "
  defp format_bullet({:ol, start}, idx), do: "#{start + idx}. "

  # ── Helpers ─────────────────────────────────────────────────────

  defp maybe_space(lines, nil), do: lines
  defp maybe_space(lines, _next), do: lines ++ [""]

  defp drop_trailing_empty([]), do: []
  defp drop_trailing_empty(["" | rest]), do: drop_trailing_empty(rest)
  defp drop_trailing_empty(lines), do: lines

  defp clamp_width(lines, width) do
    Enum.flat_map(lines, fn line -> WrapAnsi.wrap(line, width) end)
  end

  defp apply_padding_x(lines, 0), do: lines

  defp apply_padding_x(lines, px) do
    margin = String.duplicate(" ", px)
    Enum.map(lines, fn line -> margin <> line end)
  end

  defp apply_padding_y(lines, 0), do: lines

  defp apply_padding_y(lines, py) do
    empty = List.duplicate("", py)
    empty ++ lines ++ empty
  end

  # ── Table rendering ────────────────────────────────────────────

  defp render_table([], _rows, _width, _theme), do: []

  defp render_table(headers, rows, width, theme) do
    num_cols = length(headers)
    border_overhead = 3 * num_cols + 1

    available = width - border_overhead

    if available < num_cols do
      []
    else
      natural = column_natural_widths(headers, rows)
      col_widths = fit_columns(natural, available, num_cols)

      top = "┌─" <> Enum.map_join(col_widths, "─┬─", &String.duplicate("─", &1)) <> "─┐"
      sep = "├─" <> Enum.map_join(col_widths, "─┼─", &String.duplicate("─", &1)) <> "─┤"
      bottom = "└─" <> Enum.map_join(col_widths, "─┴─", &String.duplicate("─", &1)) <> "─┘"

      header_line = render_table_row(headers, col_widths, theme, true)
      row_lines = Enum.map(rows, &render_table_row(&1, col_widths, theme, false))

      body = row_lines |> Enum.intersperse([sep]) |> List.flatten()
      [top] ++ header_line ++ [sep] ++ body ++ [bottom]
    end
  end

  defp render_table_row(cells, col_widths, _theme, bold?) do
    wrapped =
      cells
      |> Enum.zip(col_widths)
      |> Enum.map(fn {text, w} -> WrapAnsi.wrap(text, max(w, 1)) end)

    max_lines = wrapped |> Enum.map(&length/1) |> Enum.max(fn -> 1 end)

    Enum.map(0..(max_lines - 1), fn line_idx ->
      parts =
        wrapped
        |> Enum.zip(col_widths)
        |> Enum.map(&format_table_cell(&1, line_idx, bold?))

      "│ " <> Enum.join(parts, " │ ") <> " │"
    end)
  end

  defp format_table_cell({cell_lines, w}, line_idx, bold?) do
    text = Enum.at(cell_lines, line_idx, "")
    vis_w = WrapAnsi.visible_width(text)
    padded = text <> String.duplicate(" ", max(0, w - vis_w))
    if bold?, do: Theme.bold(padded), else: padded
  end

  defp column_natural_widths(headers, rows) do
    num_cols = length(headers)

    Enum.map(0..(num_cols - 1), fn i ->
      header_w = WrapAnsi.visible_width(Enum.at(headers, i, ""))

      row_max =
        rows
        |> Enum.map(fn row -> WrapAnsi.visible_width(Enum.at(row, i, "")) end)
        |> Enum.max(fn -> 0 end)

      max(header_w, row_max)
    end)
  end

  defp fit_columns(natural, available, num_cols) do
    total = Enum.sum(natural)

    if total <= available do
      natural
    else
      shrink_columns(natural, available, num_cols)
    end
  end

  defp shrink_columns(natural, available, num_cols) do
    min_total = num_cols
    extra = max(0, available - min_total)
    total_weight = max(1, Enum.sum(natural))

    widths =
      Enum.map(natural, fn n ->
        1 + trunc(n / total_weight * extra)
      end)

    allocated = Enum.sum(widths)
    leftover = available - allocated
    distribute_leftover(widths, leftover)
  end

  defp distribute_leftover(widths, leftover) when leftover > 0 do
    widths
    |> Enum.with_index()
    |> Enum.map(fn {w, i} -> if i < leftover, do: w + 1, else: w end)
  end

  defp distribute_leftover(widths, _leftover), do: widths
end
