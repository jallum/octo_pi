defmodule OctoPi.TUI.Components.Markdown do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.{SyntaxHighlight, Theme}

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
    {:ok, ast, _} = EarmarkParser.as_ast(normalized)

    lines = render_nodes(ast, content_width, theme)

    lines = apply_padding_x(lines, px)
    lines = apply_padding_y(lines, py)
    lines
  end

  # ── AST node rendering ─────────────────────────────────────────

  defp render_nodes(nodes, width, theme) do
    nodes
    |> Enum.with_index()
    |> Enum.flat_map(fn {node, idx} ->
      next_type = nodes |> Enum.at(idx + 1) |> node_tag()
      render_node(node, width, theme, next_type)
    end)
  end

  defp render_node(text, _width, _theme, _next) when is_binary(text), do: [text]

  defp render_node({"h1", _, children, _}, _width, theme, next) do
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(Theme.underline(text)))
    maybe_space([styled], next)
  end

  defp render_node({"h2", _, children, _}, _width, theme, next) do
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(text))
    maybe_space([styled], next)
  end

  defp render_node({"h" <> level, _, children, _}, _width, theme, next)
       when level in ["3", "4", "5", "6"] do
    depth = String.to_integer(level)
    prefix = String.duplicate("#", depth) <> " "
    text = render_inline(children, theme)
    styled = Theme.fg(theme, :md_heading, Theme.bold(prefix <> text))
    maybe_space([styled], next)
  end

  defp render_node({"p", _, children, _}, _width, theme, next) do
    text = render_inline(children, theme)
    maybe_space([text], next)
  end

  defp render_node({"pre", _, [{"code", attrs, [code], _}], _}, _width, theme, next) do
    lang = extract_lang(attrs)
    label = "```#{lang}"

    code_lines =
      if SyntaxHighlight.supported?(lang) do
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

  defp render_node({"blockquote", _, children, _}, width, theme, next) do
    quote_width = max(1, width - 2)
    inner_lines = render_nodes(children, quote_width, theme)
    inner_lines = Enum.reverse(drop_trailing_empty(Enum.reverse(inner_lines)))

    lines =
      Enum.map(inner_lines, fn line ->
        styled = Theme.fg(theme, :md_quote, Theme.italic(line))
        Theme.fg(theme, :md_quote_border, "│ ") <> styled
      end)

    maybe_space(lines, next)
  end

  defp render_node({"ul", _, items, _}, _width, theme, _next) do
    render_list_items(items, theme, :unordered, 0)
  end

  defp render_node({"ol", attrs, items, _}, _width, theme, _next) do
    start = extract_start(attrs)
    render_list_items(items, theme, {:ordered, start}, 0)
  end

  defp render_node({"hr", _, _, _}, width, theme, next) do
    line = Theme.fg(theme, :md_hr, String.duplicate("─", min(width, 80)))
    maybe_space([line], next)
  end

  defp render_node(_node, _width, _theme, _next), do: []

  # ── Inline rendering ───────────────────────────────────────────

  defp render_inline(children, theme) do
    Enum.map_join(children, "", &render_inline_node(&1, theme))
  end

  defp render_inline_node(text, _theme) when is_binary(text), do: text

  defp render_inline_node({"strong", _, children, _}, theme) do
    Theme.bold(render_inline(children, theme))
  end

  defp render_inline_node({"em", _, children, _}, theme) do
    Theme.italic(render_inline(children, theme))
  end

  defp render_inline_node({"code", _, children, _}, theme) do
    text = render_inline(children, theme)
    Theme.fg(theme, :md_code, text)
  end

  defp render_inline_node({"del", _, children, _}, theme) do
    Theme.strikethrough(render_inline(children, theme))
  end

  defp render_inline_node({"a", attrs, children, _}, theme) do
    text = render_inline(children, theme)
    href = extract_href(attrs)
    styled = Theme.fg(theme, :md_link, Theme.underline(text))

    if href && text != href do
      styled <> Theme.fg(theme, :md_link_url, " (#{href})")
    else
      styled
    end
  end

  defp render_inline_node({"br", _, _, _}, _theme), do: "\n"

  defp render_inline_node({_tag, _, children, _}, theme) do
    render_inline(children, theme)
  end

  # ── Lists ───────────────────────────────────────────────────────

  defp render_list_items(items, theme, list_type, depth) do
    indent = String.duplicate("  ", depth)

    items
    |> Enum.with_index()
    |> Enum.flat_map(fn {{"li", _, children, _}, idx} ->
      bullet = format_bullet(list_type, idx)
      styled_bullet = Theme.fg(theme, :md_list_bullet, bullet)
      {inline, nested} = split_list_children(children)
      text = render_inline(inline, theme)

      first_line = indent <> styled_bullet <> text

      nested_lines =
        Enum.flat_map(nested, fn
          {"ul", _, sub_items, _} ->
            render_list_items(sub_items, theme, :unordered, depth + 1)

          {"ol", attrs, sub_items, _} ->
            start = extract_start(attrs)
            render_list_items(sub_items, theme, {:ordered, start}, depth + 1)

          node ->
            render_node(node, 80, theme, nil)
        end)

      [first_line | nested_lines]
    end)
  end

  defp format_bullet(:unordered, _idx), do: "- "
  defp format_bullet({:ordered, start}, idx), do: "#{start + idx}. "

  defp split_list_children(children) do
    {inline, nested} =
      Enum.split_with(children, fn
        text when is_binary(text) -> true
        {"strong", _, _, _} -> true
        {"em", _, _, _} -> true
        {"code", _, _, _} -> true
        {"del", _, _, _} -> true
        {"a", _, _, _} -> true
        {"br", _, _, _} -> true
        _ -> false
      end)

    {inline, nested}
  end

  # ── Helpers ─────────────────────────────────────────────────────

  defp maybe_space(lines, nil), do: lines
  defp maybe_space(lines, _next), do: lines ++ [""]

  defp node_tag(nil), do: nil
  defp node_tag(text) when is_binary(text), do: "text"
  defp node_tag({tag, _, _, _}), do: tag

  defp extract_lang(attrs) do
    case List.keyfind(attrs, "class", 0) do
      {"class", "language-" <> lang} -> lang
      {"class", class} -> class
      nil -> ""
    end
  end

  defp extract_href(attrs) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} -> href
      nil -> nil
    end
  end

  defp extract_start(attrs) do
    case List.keyfind(attrs, "start", 0) do
      {"start", start} -> String.to_integer(start)
      nil -> 1
    end
  end

  defp drop_trailing_empty([]), do: []
  defp drop_trailing_empty(["" | rest]), do: drop_trailing_empty(rest)
  defp drop_trailing_empty(lines), do: lines

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
end
