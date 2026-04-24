defmodule OctoPi.TUI.WrapAnsi do
  @moduledoc """
  ANSI-aware text wrapping. Splits text at word boundaries to fit
  a given column width, preserving SGR styling and OSC 8 hyperlinks
  across wrapped lines. Middle lines reset underline but preserve
  background color — matching upstream behaviour.
  """

  alias __MODULE__.Tracker

  # --- public API ---

  @doc "Visible width of a string, ignoring ANSI/OSC escape sequences."
  @spec visible_width(String.t()) :: non_neg_integer()
  def visible_width(str) do
    str
    |> strip_escapes()
    |> String.graphemes()
    |> Enum.reduce(0, fn g, acc -> acc + grapheme_width(g) end)
  end

  @doc "Wrap text at `width` columns. Handles embedded newlines and preserves ANSI codes."
  @spec wrap(String.t(), pos_integer()) :: [String.t()]
  def wrap(text, width) when width > 0 do
    lines = String.split(text, "\n")
    {result, _tracker} = wrap_lines(lines, width, %Tracker{})
    result
  end

  # --- internal: line wrapping ---

  defp wrap_lines([], _width, tracker), do: {[], tracker}

  defp wrap_lines([line | rest], width, tracker) do
    {wrapped, tracker} = wrap_single(line, width, tracker)
    {more, tracker} = wrap_lines(rest, width, tracker)
    {wrapped ++ more, tracker}
  end

  defp wrap_single(line, width, tracker) do
    tokens = tokenize(line)
    build_lines(tokens, width, tracker, "", 0, [])
  end

  # --- tokenizer ---
  # Splits a line into [{:word, text} | {:space, text}] tokens,
  # attaching ANSI codes to the following visible character (so
  # codes between a word and a space end up on the next token).

  defp tokenize(line), do: do_tok(line, "", "", false, [])

  defp do_tok("", pending, current, is_ws, acc) do
    final = current <> pending
    if final == "", do: Enum.reverse(acc), else: Enum.reverse([seg(is_ws, final) | acc])
  end

  defp do_tok(<<"\e", _::binary>> = input, pending, current, is_ws, acc) do
    {code, rest} = extract_escape_seq(input)
    do_tok(rest, pending <> code, current, is_ws, acc)
  end

  defp do_tok(<<c::utf8, rest::binary>>, pending, current, is_ws, acc) do
    char = <<c::utf8>>
    char_ws = whitespace_char?(char)

    if current != "" and char_ws != is_ws do
      tok = seg(is_ws, current)
      do_tok(rest, "", pending <> char, char_ws, [tok | acc])
    else
      do_tok(rest, "", current <> pending <> char, char_ws, acc)
    end
  end

  defp seg(true, text), do: {:space, text}
  defp seg(false, text), do: {:word, text}

  # --- escape sequence extraction ---

  defp extract_escape_seq(<<"\e[", rest::binary>>) do
    {body, remaining} = take_csi_body(rest)
    {"\e[" <> body, remaining}
  end

  defp extract_escape_seq(<<"\e]", rest::binary>>) do
    {body, remaining} = take_osc_body(rest)
    {"\e]" <> body, remaining}
  end

  defp extract_escape_seq(<<"\e_", rest::binary>>) do
    {body, remaining} = take_osc_body(rest)
    {"\e_" <> body, remaining}
  end

  defp extract_escape_seq(<<"\e", c::8, rest::binary>>), do: {<<"\e", c>>, rest}
  defp extract_escape_seq(<<c::8, rest::binary>>), do: {<<c>>, rest}

  defp take_csi_body(<<>>), do: {"", ""}
  defp take_csi_body(<<b::8, rest::binary>>) when b >= 0x40 and b <= 0x7E, do: {<<b>>, rest}

  defp take_csi_body(<<b::8, rest::binary>>) do
    {tail, remaining} = take_csi_body(rest)
    {<<b>> <> tail, remaining}
  end

  defp take_osc_body(<<>>), do: {"", ""}
  defp take_osc_body(<<0x07, rest::binary>>), do: {<<0x07>>, rest}
  defp take_osc_body(<<"\e\\", rest::binary>>), do: {"\e\\", rest}

  defp take_osc_body(<<b::8, rest::binary>>) do
    {tail, remaining} = take_osc_body(rest)
    {<<b>> <> tail, remaining}
  end

  # --- build wrapped output lines from tokens ---

  defp build_lines([], _width, tracker, current, _cw, completed),
    do: {Enum.reverse([current | completed]), tracker}

  defp build_lines([{:space, text} | rest], width, tracker, current, cw, completed) do
    sw = visible_width(text)

    if cw + sw <= width do
      tracker = process_ansi_in(tracker, text)
      build_lines(rest, width, tracker, current <> text, cw + sw, completed)
    else
      line_end = Tracker.line_end_reset(tracker)
      line_start = Tracker.active_codes(tracker)
      tracker = process_ansi_in(tracker, text)
      trimmed = String.trim_trailing(current)
      build_lines(rest, width, tracker, line_start, 0, [trimmed <> line_end | completed])
    end
  end

  defp build_lines([{:word, text} | rest], width, tracker, current, cw, completed) do
    ww = visible_width(text)

    cond do
      cw + ww <= width ->
        tracker = process_ansi_in(tracker, text)
        build_lines(rest, width, tracker, current <> text, cw + ww, completed)

      cw == 0 ->
        {lines, leftover, lw, tracker} = break_word(current, text, width, tracker)
        new_completed = lines ++ completed
        build_lines(rest, width, tracker, leftover, lw, new_completed)

      true ->
        line_end = Tracker.line_end_reset(tracker)
        line_start = Tracker.active_codes(tracker)
        trimmed = String.trim_trailing(current)

        build_lines([{:word, text} | rest], width, tracker, line_start, 0, [
          trimmed <> line_end | completed
        ])
    end
  end

  # --- word breaking ---

  defp break_word(prefix, text, width, tracker) do
    parts = split_ansi_and_visible(text)
    do_break(parts, width, tracker, prefix, 0, [])
  end

  defp do_break([], _width, tracker, current, cw, lines),
    do: {lines, current, cw, tracker}

  defp do_break([{:ansi, code} | rest], width, tracker, current, cw, lines) do
    tracker = Tracker.process(tracker, code)
    do_break(rest, width, tracker, current <> code, cw, lines)
  end

  defp do_break([{:visible, g} | rest], width, tracker, current, cw, lines) do
    gw = grapheme_width(g)

    if cw + gw > width do
      line_end = Tracker.line_end_reset(tracker)
      line_start = Tracker.active_codes(tracker)

      do_break([{:visible, g} | rest], width, tracker, line_start, 0, [
        current <> line_end | lines
      ])
    else
      do_break(rest, width, tracker, current <> g, cw + gw, lines)
    end
  end

  defp split_ansi_and_visible(text), do: do_split_av(text, [])

  defp do_split_av("", acc), do: Enum.reverse(acc)

  defp do_split_av(<<"\e", _::binary>> = input, acc) do
    {code, rest} = extract_escape_seq(input)
    do_split_av(rest, [{:ansi, code} | acc])
  end

  defp do_split_av(bin, acc) do
    case String.next_grapheme(bin) do
      {g, rest} -> do_split_av(rest, [{:visible, g} | acc])
      nil -> Enum.reverse(acc)
    end
  end

  # --- ANSI processing helper ---

  defp process_ansi_in(tracker, text) do
    text
    |> extract_codes()
    |> Enum.reduce(tracker, &Tracker.process(&2, &1))
  end

  defp extract_codes(text), do: do_extract_codes(text, [])

  defp do_extract_codes("", acc), do: Enum.reverse(acc)

  defp do_extract_codes(<<"\e", _::binary>> = input, acc) do
    {code, rest} = extract_escape_seq(input)
    do_extract_codes(rest, [code | acc])
  end

  defp do_extract_codes(<<_::utf8, rest::binary>>, acc), do: do_extract_codes(rest, acc)

  # --- visible width helpers ---

  defp strip_escapes(str), do: do_strip(str, "")

  defp do_strip("", acc), do: acc
  defp do_strip(<<"\e[", rest::binary>>, acc), do: do_strip(skip_csi(rest), acc)
  defp do_strip(<<"\e]", rest::binary>>, acc), do: do_strip(skip_osc(rest), acc)
  defp do_strip(<<"\e_", rest::binary>>, acc), do: do_strip(skip_osc(rest), acc)
  defp do_strip(<<"\e", _::8, rest::binary>>, acc), do: do_strip(rest, acc)
  defp do_strip(<<c::utf8, rest::binary>>, acc), do: do_strip(rest, acc <> <<c::utf8>>)

  defp skip_csi(<<>>), do: ""
  defp skip_csi(<<b::8, rest::binary>>) when b >= 0x40 and b <= 0x7E, do: rest
  defp skip_csi(<<_::8, rest::binary>>), do: skip_csi(rest)

  defp skip_osc(<<>>), do: ""
  defp skip_osc(<<0x07, rest::binary>>), do: rest
  defp skip_osc(<<"\e\\", rest::binary>>), do: rest
  defp skip_osc(<<_::8, rest::binary>>), do: skip_osc(rest)

  # --- character classification ---

  defp whitespace_char?(" "), do: true
  defp whitespace_char?("\t"), do: true
  defp whitespace_char?(_), do: false

  # --- grapheme width (East Asian Width + emoji heuristic) ---

  @doc false
  def grapheme_width(<<cp::utf8>>) do
    cond do
      cp <= 0x1F -> 0
      wide_codepoint?(cp) -> 2
      true -> 1
    end
  end

  def grapheme_width(_), do: 2

  defp wide_codepoint?(cp) do
    (cp >= 0x1100 and cp <= 0x115F) or
      (cp >= 0x231A and cp <= 0x232A) or
      (cp >= 0x23E9 and cp <= 0x23F3) or
      (cp >= 0x23F8 and cp <= 0x23FA) or
      (cp >= 0x25FD and cp <= 0x25FE) or
      (cp >= 0x2614 and cp <= 0x2615) or
      (cp >= 0x2648 and cp <= 0x2653) or
      (cp >= 0x267F and cp <= 0x267F) or
      (cp >= 0x2693 and cp <= 0x2693) or
      (cp >= 0x26A1 and cp <= 0x26A1) or
      (cp >= 0x26AA and cp <= 0x26AB) or
      (cp >= 0x26BD and cp <= 0x26BE) or
      (cp >= 0x26C4 and cp <= 0x26C5) or
      (cp >= 0x26D4 and cp <= 0x26D4) or
      (cp >= 0x26EA and cp <= 0x26EA) or
      (cp >= 0x26F2 and cp <= 0x26F3) or
      (cp >= 0x26F5 and cp <= 0x26F5) or
      (cp >= 0x26FA and cp <= 0x26FA) or
      (cp >= 0x26FD and cp <= 0x26FD) or
      (cp >= 0x2702 and cp <= 0x2702) or
      (cp >= 0x2705 and cp <= 0x2705) or
      (cp >= 0x2708 and cp <= 0x270D) or
      (cp >= 0x270F and cp <= 0x270F) or
      (cp >= 0x2712 and cp <= 0x2712) or
      (cp >= 0x2714 and cp <= 0x2714) or
      (cp >= 0x2716 and cp <= 0x2716) or
      (cp >= 0x271D and cp <= 0x271D) or
      (cp >= 0x2721 and cp <= 0x2721) or
      (cp >= 0x2728 and cp <= 0x2728) or
      (cp >= 0x2733 and cp <= 0x2734) or
      (cp >= 0x2744 and cp <= 0x2744) or
      (cp >= 0x2747 and cp <= 0x2747) or
      (cp >= 0x274C and cp <= 0x274C) or
      (cp >= 0x274E and cp <= 0x274E) or
      (cp >= 0x2753 and cp <= 0x2755) or
      (cp >= 0x2757 and cp <= 0x2757) or
      (cp >= 0x2763 and cp <= 0x2764) or
      (cp >= 0x2795 and cp <= 0x2797) or
      (cp >= 0x27A1 and cp <= 0x27A1) or
      (cp >= 0x27B0 and cp <= 0x27B0) or
      (cp >= 0x27BF and cp <= 0x27BF) or
      (cp >= 0x2934 and cp <= 0x2935) or
      (cp >= 0x2B05 and cp <= 0x2B07) or
      (cp >= 0x2B1B and cp <= 0x2B1C) or
      (cp >= 0x2B50 and cp <= 0x2B50) or
      (cp >= 0x2B55 and cp <= 0x2B55) or
      (cp >= 0x2E80 and cp <= 0x303E) or
      (cp >= 0x3040 and cp <= 0x33FF) or
      (cp >= 0x3400 and cp <= 0x4DBF) or
      (cp >= 0x4E00 and cp <= 0xA4CF) or
      (cp >= 0xAC00 and cp <= 0xD7AF) or
      (cp >= 0xF900 and cp <= 0xFAFF) or
      (cp >= 0xFE10 and cp <= 0xFE19) or
      (cp >= 0xFE30 and cp <= 0xFE6F) or
      (cp >= 0xFF01 and cp <= 0xFF60) or
      (cp >= 0xFFE0 and cp <= 0xFFE6) or
      (cp >= 0x1F000 and cp <= 0x1FAFF) or
      (cp >= 0x1F1E6 and cp <= 0x1F1FF) or
      (cp >= 0x20000 and cp <= 0x323AF)
  end
end
