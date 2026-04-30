defmodule OctoPi.TUI.Components.Markdown.Lexer do
  @moduledoc """
  Hand-rolled, line-oriented Markdown lexer producing an
  Earmark-compatible AST so the existing `Components.Markdown` token
  walker keeps working unchanged.

  Output shape per node: `{tag, attrs, children, meta}` where:
    - `tag` is a String like `"h1"`, `"p"`, `"pre"`, `"blockquote"`,
      `"ul"`, `"ol"`, `"li"`, `"hr"`, `"table"`, `"thead"`, `"tbody"`,
      `"tr"`, `"th"`, `"td"`.
    - `attrs` is a list of `{key, value}` 2-tuples (e.g. `{"class",
      "language-elixir"}`, `{"start", "1"}`, `{"href", "..."}`).
    - `children` is a list of nodes or strings.
    - `meta` is unused (`%{}`).

  Inline children include bare strings and inline tags `"strong"`,
  `"em"`, `"code"`, `"del"`, `"a"`, `"br"`. We do not emit `"text"`
  pseudo-tags — bare strings stand in.

  This module is intentionally pure — `tokenize/1` is a function from
  text to AST. Streaming uses the same lexer over the line-checkpointed
  source held by `OctoPi.TUI.StreamingMarkdown`.

  Out of scope (matches the existing renderer's behavior):
    - Setext headings (`===` / `---` underlines).
    - Reference-style links (`[text][ref]` + `[ref]: url`).
    - HTML blocks beyond raw passthrough as text.
  """

  @type ast_node :: {String.t(), list({String.t(), String.t()}), list(ast_node | String.t()), map()}

  @doc """
  Parse Markdown text into an Earmark-compatible AST.
  """
  @spec tokenize(String.t()) :: [ast_node]
  def tokenize(text) when is_binary(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> parse_blocks()
  end

  # ── Block parser ────────────────────────────────────────────────
  #
  # Multi-head pattern matching: each clause recognizes one block kind
  # by inspecting the leading line, emits the AST node directly, and
  # recurses on the remaining lines. No intermediate classification
  # tagged tuple — we parse and produce in one pass.
  #
  # Order matters where prefix patterns overlap (e.g. `- ` for list
  # items must run before HR detection so `- foo` is not mistaken for
  # a 3-dash divider, and HR runs before paragraph fallback).

  defp parse_blocks(lines), do: parse_blocks(lines, [])

  defp parse_blocks([], acc), do: Enum.reverse(acc)
  defp parse_blocks(["" | rest], acc), do: parse_blocks(rest, acc)
  defp parse_blocks([line | rest], acc), do: parse_block(line, rest, acc)

  # Non-empty lines dispatch by content. Pattern-match where unambiguous
  # binary prefixes exist; predicate guards for content-dependent
  # shapes (HR, list, table). Each clause emits the AST node directly
  # and recurses — no intermediate classification tuple.
  defp parse_block(line, rest, acc) do
    cond do
      String.trim(line) == "" ->
        parse_blocks(rest, acc)

      heading = parse_heading(line) ->
        {level, text} = heading
        parse_blocks(rest, [{"h#{level}", [], parse_inline(text), %{}} | acc])

      fence = parse_fence_open(line) ->
        {marker, lang} = fence
        {code_lines, after_close} = take_until_fence_close(rest, marker, [])
        code = Enum.join(code_lines, "\n")
        attrs = if lang == "", do: [], else: [{"class", "language-#{lang}"}]
        node = {"pre", [], [{"code", attrs, [code], %{}}], %{}}
        parse_blocks(after_close, [node | acc])

      list_open = parse_list_item_open(line) ->
        {kind, indent, _start, _text} = list_open
        all = [line | rest]
        {items, remaining} = collect_items(all, kind, indent, [])
        parse_blocks(remaining, [build_list_node(kind, items, all) | acc])

      hr?(line) ->
        parse_blocks(rest, [{"hr", [], [], %{}} | acc])

      blockquote?(line) ->
        {qlines, remaining} = take_blockquote_lines([line | rest], [])
        inner = qlines |> Enum.join("\n") |> tokenize()
        parse_blocks(remaining, [{"blockquote", [], inner, %{}} | acc])

      table?(line, rest) ->
        [sep | body_rest] = rest
        _aligns = parse_table_alignments(sep)
        headers = parse_table_row(line)
        {body_rows, after_table} = take_table_body(body_rest, [])
        thead = {"thead", [], [{"tr", [], Enum.map(headers, &{"th", [], parse_inline(&1), %{}}), %{}}], %{}}

        tbody =
          {"tbody", [],
           Enum.map(body_rows, fn cells ->
             {"tr", [], Enum.map(cells, &{"td", [], parse_inline(&1), %{}}), %{}}
           end), %{}}

        parse_blocks(after_table, [{"table", [], [thead, tbody], %{}} | acc])

      true ->
        {plines, remaining} = take_paragraph_lines(rest, [line])
        text = Enum.join(plines, "\n")
        parse_blocks(remaining, [{"p", [], parse_inline(text), %{}} | acc])
    end
  end

  defp blank?(line), do: String.trim(line) == ""

  # HR: a line with three or more `-`, `*`, or `_`, optionally separated by spaces.
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

  # ATX heading: 1-6 `#`s followed by space and text, optional trailing `#`s.
  defp parse_heading(line) do
    case Regex.run(~r/^([#]{1,6})\s+(.*?)\s*[#]*\s*$/, line) do
      [_, hashes, text] -> {String.length(hashes), text}
      _ -> nil
    end
  end

  # Code fence: ``` or ~~~ with optional language at the start, optional leading spaces.
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

  # Strip the leading `>` (and optional space) off contiguous blockquote
  # lines and return the unwrapped content. The unwrapped lines get
  # re-tokenized so nested constructs (lists, code, etc.) work.
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

  defp parse_table_alignments(_sep_line), do: []

  # ── Lists ───────────────────────────────────────────────────────

  # Returns a 4-tuple `{kind, indent, start_or_nil, text}` so all
  # downstream pattern-matching can use one consistent shape.
  # `kind` is `:unordered` (start_or_nil = nil) or `:ordered` (start
  # is the numeric value of the leading marker).
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

  defp build_list_node(:unordered, items, _lines), do: {"ul", [], items, %{}}

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

    attrs = if start == 1, do: [], else: [{"start", Integer.to_string(start)}]
    {"ol", attrs, items, %{}}
  end

  defp collect_items([], _kind, _base, acc), do: {Enum.reverse(acc), []}

  defp collect_items([line | rest] = all, kind, base, acc) do
    case parse_list_item_open(line) do
      nil ->
        if blank?(line) do
          case rest do
            [next | _] ->
              case parse_list_item_open(next) do
                {^kind, ^base, _, _} -> collect_items(rest, kind, base, acc)
                _ -> {Enum.reverse(acc), all}
              end

            [] ->
              {Enum.reverse(acc), []}
          end
        else
          {Enum.reverse(acc), all}
        end

      {^kind, ^base, _start, _text} = open ->
        {item_children, leftover} = consume_item_body(open, rest, base)
        item = {"li", [], item_children, %{}}
        collect_items(leftover, kind, base, [item | acc])

      {_other_kind, ^base, _start, _text} ->
        # Different kind at same indent — list breaks here.
        {Enum.reverse(acc), all}

      _ ->
        # Different indent — handled by take_nested in the parent item.
        {Enum.reverse(acc), all}
    end
  end

  defp consume_item_body({_, _, _, text}, rest, base) do
    inline = parse_inline(text)
    {nested, leftover} = take_nested(rest, base, [])
    {inline ++ nested, leftover}
  end

  # Look for a nested list starting at indent > base.
  defp take_nested([], _base, acc), do: {Enum.reverse(acc), []}

  defp take_nested([line | rest] = all, base, acc) do
    case parse_list_item_open(line) do
      {kind, indent, _start, _text} when indent > base ->
        nested_list_lines = [line | rest]
        {items, remaining} = collect_items(nested_list_lines, kind, indent, [])
        nested_node = build_list_node(kind, items, nested_list_lines)
        take_nested(remaining, base, [nested_node | acc])

      _ ->
        if blank?(line) do
          case rest do
            [next | _] ->
              case parse_list_item_open(next) do
                {_, indent, _, _} when indent > base -> take_nested(rest, base, acc)
                _ -> {Enum.reverse(acc), all}
              end

            _ ->
              {Enum.reverse(acc), all}
          end
        else
          {Enum.reverse(acc), all}
        end
    end
  end

  # ── Paragraphs ──────────────────────────────────────────────────
  #
  # Take consecutive non-blank lines until we hit a blank or a line
  # that starts a different block. Returns {paragraph_lines, remaining}.

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

  # Inline parsing is delegated to the leex-generated lexer wrapped
  # by `OctoPi.TUI.Components.Markdown.Inline`.
  defp parse_inline(text), do: OctoPi.TUI.Components.Markdown.Inline.parse(text)
end
