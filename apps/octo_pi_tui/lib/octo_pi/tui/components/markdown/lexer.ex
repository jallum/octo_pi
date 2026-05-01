defmodule OctoPi.TUI.Components.Markdown.Lexer do
  @moduledoc """
  Line-oriented Markdown lexer producing a native, atom-based AST.

      block ::= {:heading, 1..6, [inline]}
              | {:paragraph, [inline]}
              | {:code_block, lang :: String.t() | nil, code :: String.t()}
              | {:blockquote, [block]}
              | {:list, :ul | {:ol, start :: integer}, [list_item]}
              | :hr
              | {:table, [[inline]], [[[inline]]]}

      list_item ::= {:li, [inline], [block]}

      inline ::= see `OctoPi.TUI.Components.Markdown.Inline`

  Pure: `tokenize/1` is a function from text to AST. Streaming uses the
  same lexer over line-checkpointed source held by the streaming wrapper.

  Out of scope (matches the existing renderer's behavior):
    - Setext headings (`===` / `---` underlines).
    - Reference-style links (`[text][ref]` + `[ref]: url`).
    - HTML blocks beyond raw passthrough as text.
  """

  alias OctoPi.TUI.Components.Markdown.Inline

  @type inline :: Inline.inline()

  @type list_kind :: :ul | {:ol, integer()}

  @type list_item :: {:li, [inline], [block]}

  @type block ::
          {:heading, 1..6, [inline]}
          | {:paragraph, [inline]}
          | {:code_block, String.t() | nil, String.t()}
          | {:blockquote, [block]}
          | {:list, list_kind, [list_item]}
          | :hr
          | {:table, [[inline]], [[[inline]]]}

  @spec tokenize(String.t()) :: [block]
  def tokenize(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> parse_blocks()
  end

  # ── Block parser ────────────────────────────────────────────────

  defp parse_blocks(lines), do: parse_blocks(lines, [])

  defp parse_blocks([], acc), do: Enum.reverse(acc)
  defp parse_blocks(["" | rest], acc), do: parse_blocks(rest, acc)
  defp parse_blocks([line | rest], acc), do: parse_block(line, rest, acc)

  defp parse_block(line, rest, acc) do
    cond do
      blank?(line) ->
        parse_blocks(rest, acc)

      heading = parse_heading(line) ->
        {level, text} = heading
        parse_blocks(rest, [{:heading, level, parse_inline(text)} | acc])

      fence = parse_fence_open(line) ->
        parse_block_fence(fence, rest, acc)

      list_open = parse_list_item_open(line) ->
        parse_block_list(list_open, line, rest, acc)

      hr?(line) ->
        parse_blocks(rest, [:hr | acc])

      blockquote?(line) ->
        parse_block_blockquote(line, rest, acc)

      true ->
        parse_block_table_or_paragraph(line, rest, acc)
    end
  end

  defp parse_block_fence({marker, lang}, rest, acc) do
    {code_lines, after_close} = take_until_fence_close(rest, marker, [])
    code = Enum.join(code_lines, "\n")
    lang = if lang == "", do: nil, else: lang
    parse_blocks(after_close, [{:code_block, lang, code} | acc])
  end

  defp parse_block_list({kind, indent, _start, _text}, line, rest, acc) do
    all = [line | rest]
    {items, remaining} = collect_items(all, kind, indent, [])
    parse_blocks(remaining, [build_list_node(kind, items, all) | acc])
  end

  defp parse_block_blockquote(line, rest, acc) do
    {qlines, remaining} = take_blockquote_lines([line | rest], [])
    inner = qlines |> Enum.join("\n") |> tokenize()
    parse_blocks(remaining, [{:blockquote, inner} | acc])
  end

  defp parse_block_table_or_paragraph(line, rest, acc) do
    if table?(line, rest) do
      [_sep | body_rest] = rest
      headers = line |> parse_table_row() |> Enum.map(&parse_inline/1)
      {body_rows, after_table} = take_table_body(body_rest, [])
      rows = Enum.map(body_rows, fn cells -> Enum.map(cells, &parse_inline/1) end)
      parse_blocks(after_table, [{:table, headers, rows} | acc])
    else
      {plines, remaining} = take_paragraph_lines(rest, [line])
      text = Enum.join(plines, "\n")
      parse_blocks(remaining, [{:paragraph, parse_inline(text)} | acc])
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  defp hr?(line) do
    trimmed = String.trim(line)

    case trimmed do
      "" ->
        false

      _ ->
        chars = String.replace(trimmed, " ", "")

        cond do
          String.length(chars) < 3 -> false
          String.match?(chars, ~r/^-+$/) -> true
          String.match?(chars, ~r/^\*+$/) -> true
          String.match?(chars, ~r/^_+$/) -> true
          true -> false
        end
    end
  end

  defp parse_heading(line) do
    case Regex.run(~r/^([#]{1,6})\s+(.*?)\s*[#]*\s*$/, line) do
      [_, hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  defp parse_fence_open(line) do
    case Regex.run(~r/^\s{0,3}(```|~~~)\s*([^\s`~]*)\s*$/, line) do
      [_, marker, lang] -> {marker, lang}
      _ -> nil
    end
  end

  defp take_until_fence_close([], _marker, acc), do: {Enum.reverse(acc), []}

  defp take_until_fence_close([line | rest], marker, acc) do
    if fence_close?(line, marker) do
      {Enum.reverse(acc), rest}
    else
      take_until_fence_close(rest, marker, [line | acc])
    end
  end

  defp fence_close?(line, marker) do
    String.match?(line, ~r/^\s{0,3}#{Regex.escape(marker)}\s*$/)
  end

  defp blockquote?(line), do: String.match?(line, ~r/^\s{0,3}>/)

  defp take_blockquote_lines([], acc), do: {Enum.reverse(acc), []}

  defp take_blockquote_lines([line | rest] = all, acc) do
    if blockquote?(line) do
      stripped = String.replace(line, ~r/^\s{0,3}>\s?/, "")
      take_blockquote_lines(rest, [stripped | acc])
    else
      {Enum.reverse(acc), all}
    end
  end

  # ── Tables ──────────────────────────────────────────────────────

  defp table?(line, rest) do
    table_row?(line) and rest != [] and table_separator?(hd(rest))
  end

  defp table_row?(line), do: String.match?(line, ~r/^\s*\|.*\|\s*$/)

  defp table_separator?(line) do
    String.match?(line, ~r/^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$/)
  end

  defp take_table_body([], acc), do: {Enum.reverse(acc), []}

  defp take_table_body([line | rest], acc) do
    if table_row?(line) do
      take_table_body(rest, [parse_table_row(line) | acc])
    else
      {Enum.reverse(acc), [line | rest]}
    end
  end

  defp parse_table_row(line) do
    line
    |> String.trim()
    |> String.replace(~r/^\|/, "")
    |> String.replace(~r/\|\s*$/, "")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  # ── Lists ───────────────────────────────────────────────────────

  defp parse_list_item_open(line) do
    cond do
      m = Regex.run(~r/^(\s*)([-*+])\s+(.*)$/, line) ->
        [_, indent, _bullet, rest] = m
        {:unordered, String.length(indent), nil, rest}

      m = Regex.run(~r/^(\s*)(\d+)\.\s+(.*)$/, line) ->
        [_, indent, num, rest] = m
        {:ordered, String.length(indent), String.to_integer(num), rest}

      true ->
        nil
    end
  end

  defp build_list_node(:unordered, items, _lines), do: {:list, :ul, items}

  defp build_list_node(:ordered, items, lines) do
    start =
      case List.first(lines) do
        nil ->
          1

        first_line ->
          case parse_list_item_open(first_line) do
            {:ordered, _, n, _} -> n
            _ -> 1
          end
      end

    {:list, {:ol, start}, items}
  end

  defp collect_items([], _kind, _base, acc), do: {Enum.reverse(acc), []}

  defp collect_items([line | rest] = all, kind, base, acc) do
    collect_items_step(parse_list_item_open(line), blank?(line), rest, all, kind, base, acc)
  end

  defp collect_items_step({kind, base, _start, _text} = open, _blank, rest, _all, kind, base, acc) do
    {inline, nested, leftover} = consume_item_body(open, rest, base)
    collect_items(leftover, kind, base, [{:li, inline, nested} | acc])
  end

  defp collect_items_step(nil, true, [next | _] = rest, all, kind, base, acc) do
    case parse_list_item_open(next) do
      {^kind, ^base, _, _} -> collect_items(rest, kind, base, acc)
      _ -> {Enum.reverse(acc), all}
    end
  end

  defp collect_items_step(nil, true, [], _all, _kind, _base, acc), do: {Enum.reverse(acc), []}

  defp collect_items_step(_open, _blank, _rest, all, _kind, _base, acc) do
    {Enum.reverse(acc), all}
  end

  defp consume_item_body({_, _, _, text}, rest, base) do
    inline = parse_inline(text)
    {nested, leftover} = take_nested(rest, base, [])
    {inline, nested, leftover}
  end

  defp take_nested([], _base, acc), do: {Enum.reverse(acc), []}

  defp take_nested([line | rest] = all, base, acc) do
    take_nested_step(parse_list_item_open(line), blank?(line), line, rest, all, base, acc)
  end

  defp take_nested_step({kind, indent, _start, _text}, _blank, line, rest, _all, base, acc)
       when indent > base do
    nested_list_lines = [line | rest]
    {items, remaining} = collect_items(nested_list_lines, kind, indent, [])
    nested_node = build_list_node(kind, items, nested_list_lines)
    take_nested(remaining, base, [nested_node | acc])
  end

  defp take_nested_step(_open, true, _line, [next | _] = rest, all, base, acc) do
    case parse_list_item_open(next) do
      {_, indent, _, _} when indent > base -> take_nested(rest, base, acc)
      _ -> {Enum.reverse(acc), all}
    end
  end

  defp take_nested_step(_open, _blank, _line, _rest, all, _base, acc) do
    {Enum.reverse(acc), all}
  end

  # ── Paragraphs ──────────────────────────────────────────────────

  defp take_paragraph_lines([], acc), do: {Enum.reverse(acc), []}

  defp take_paragraph_lines([line | rest] = all, acc) do
    cond do
      String.trim(line) == "" -> {Enum.reverse(acc), rest}
      paragraph_breaks?(line) -> {Enum.reverse(acc), all}
      true -> take_paragraph_lines(rest, [line | acc])
    end
  end

  defp paragraph_breaks?(line) do
    hr?(line) or
      parse_heading(line) != nil or
      parse_fence_open(line) != nil or
      blockquote?(line) or
      parse_list_item_open(line) != nil
  end

  defp parse_inline(text), do: Inline.parse(text)
end
