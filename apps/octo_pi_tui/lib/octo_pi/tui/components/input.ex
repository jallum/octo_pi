defmodule OctoPi.TUI.Components.Input do
  @moduledoc """
  Editable text input with display-width-aware wrapping, Emacs-style
  kill ring, undo stack, and word-boundary navigation.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.Suggestion
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  @page_size 10

  @max_history 1000

  @type t :: %__MODULE__{
          value: String.t(),
          cursor: non_neg_integer(),
          width: pos_integer(),
          height: pos_integer(),
          padding_x: non_neg_integer(),
          theme: Theme.t() | nil,
          kill_ring: [String.t()],
          last_action: :kill | :yank | :type_word | nil,
          undo_stack: [{String.t(), non_neg_integer()}],
          preferred_col: non_neg_integer() | nil,
          autocomplete_provider: struct() | nil,
          autocomplete_suggestions: [Suggestion.t()],
          autocomplete_selected: non_neg_integer(),
          autocomplete_active: boolean(),
          scroll_offset: non_neg_integer(),
          history: [String.t()],
          history_index: non_neg_integer() | nil,
          saved_input: String.t() | nil
        }

  defstruct value: "",
            cursor: 0,
            width: 80,
            height: 24,
            padding_x: 0,
            theme: nil,
            kill_ring: [],
            last_action: nil,
            undo_stack: [],
            preferred_col: nil,
            autocomplete_provider: nil,
            autocomplete_suggestions: [],
            autocomplete_selected: 0,
            autocomplete_active: false,
            scroll_offset: 0,
            history: [],
            history_index: nil,
            saved_input: nil

  @min_visible_lines 5

  defp layout_width(width, padding_x) do
    max_padding = max(0, div(width - 1, 2))
    px = min(padding_x, max_padding)
    content_w = max(1, width - px * 2)
    lw = if px > 0, do: content_w, else: max(1, content_w - 1)
    {px, content_w, lw}
  end

  @doc "Update scroll_offset to keep cursor visible within the viewport."
  @spec update_scroll(t(), pos_integer()) :: t()
  def update_scroll(%__MODULE__{height: height, padding_x: px} = input, width) do
    {_, _, lw} = layout_width(width, px)
    max_visible = max(@min_visible_lines, div(height * 3, 10))
    all_lines = layout_lines(input.value, lw)
    total = length(all_lines)
    {cursor_row, _} = content_rc(input, lw)
    new_offset = scroll_for_cursor(input.scroll_offset, cursor_row, max_visible, total)
    %{input | scroll_offset: new_offset}
  end

  @reverse_on "\e[7m"
  @reverse_off "\e[27m"

  # --- render ---

  @impl true
  def render(%__MODULE__{value: value, theme: theme, height: height, padding_x: px} = input, width) do
    {effective_px, content_w, lw} = layout_width(width, px)
    all_lines = layout_lines(value, lw)

    {cursor_row, cursor_col} = content_rc(input, lw)
    all_lines = inject_cursor(all_lines, cursor_row, cursor_col)

    padded = pad_content_lines(all_lines, effective_px, content_w)

    max_visible = max(@min_visible_lines, div(height * 3, 10))
    total = length(padded)

    if total <= max_visible do
      [border_line(theme, width) | padded] ++ [border_line(theme, width)]
    else
      {cursor_row, _} = content_rc(input, lw)
      offset = scroll_for_cursor(input.scroll_offset, cursor_row, max_visible, total)
      visible = Enum.slice(padded, offset, max_visible)
      lines_above = offset
      lines_below = total - offset - length(visible)

      top = scroll_border(theme, width, :up, lines_above)
      bottom = scroll_border(theme, width, :down, lines_below)
      [top | visible] ++ [bottom]
    end
  end

  @doc "Cursor position within the rendered output as `{row, col}` (0-indexed, display-width columns). Row includes the top border line."
  @spec cursor_rc(t(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_rc(%__MODULE__{height: height, padding_x: px} = input, width) do
    {effective_px, _, lw} = layout_width(width, px)
    {row, col} = content_rc(input, lw)
    max_visible = max(@min_visible_lines, div(height * 3, 10))
    all_lines = layout_lines(input.value, lw)
    total = length(all_lines)

    offset_row =
      if total <= max_visible do
        row + 1
      else
        offset = scroll_for_cursor(input.scroll_offset, row, max_visible, total)
        row - offset + 1
      end

    {offset_row, col + effective_px}
  end

  defp content_rc(%__MODULE__{value: value, cursor: cursor}, lw) do
    value
    |> String.graphemes()
    |> Enum.take(cursor)
    |> Enum.reduce({0, 0}, &advance_rc(&1, &2, lw))
    |> then(fn {row, col} ->
      if col >= lw, do: {row + 1, 0}, else: {row, col}
    end)
  end

  defp layout_lines(value, lw) do
    value |> String.split("\n") |> Enum.flat_map(&wrap_input(&1, lw))
  end

  defp pad_content_lines(lines, 0, _content_w), do: lines

  defp pad_content_lines(lines, px, content_w) do
    pad = String.duplicate(" ", px)

    Enum.map(lines, fn line ->
      line_w = WrapAnsi.visible_width(line)
      right_fill = String.duplicate(" ", max(0, content_w - line_w))
      pad <> line <> right_fill <> pad
    end)
  end

  # --- public API ---

  @doc "Set the value, clamping cursor. Preserves kill ring, undo, etc."
  @spec set_value(t(), String.t()) :: t()
  def set_value(%__MODULE__{cursor: c} = s, value), do: %{s | value: value, cursor: min(c, String.length(value))}

  @doc "Insert a char at the cursor (from KeyParser {:char, _} events)."
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{value: v, cursor: c} = s, char) do
    s = if whitespace?(char) or s.last_action != :type_word, do: push_undo(s), else: s
    {before, after_cursor} = split_at_grapheme(v, c)

    refresh_autocomplete(%{
      s
      | value: before <> char <> after_cursor,
        cursor: c + String.length(char),
        last_action: :type_word,
        history_index: nil
    })
  end

  @doc "Insert pasted text atomically (single undo unit)."
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{value: v, cursor: c} = s, text) do
    clean =
      text
      |> String.replace("\r\n", "\n")
      |> String.replace("\r", "\n")
      |> String.replace("\t", "    ")

    s = push_undo(s)
    {before, after_cursor} = split_at_grapheme(v, c)

    %{
      s
      | value: before <> clean <> after_cursor,
        cursor: c + String.length(clean),
        last_action: nil
    }
  end

  # --- handle_key: multi-head dispatch ---

  @impl true
  def handle_key(%__MODULE__{} = s, %Key{key: ?-, modifiers: [:ctrl]}), do: undo(s)

  def handle_key(%__MODULE__{autocomplete_active: true} = s, %Key{key: :up}), do: autocomplete_navigate(s, -1)

  def handle_key(%__MODULE__{autocomplete_active: true} = s, %Key{key: :down}), do: autocomplete_navigate(s, 1)

  def handle_key(%__MODULE__{autocomplete_active: true} = s, %Key{key: :tab}), do: autocomplete_accept(s)

  def handle_key(%__MODULE__{autocomplete_active: true} = s, %Key{key: :enter}), do: autocomplete_accept(s)

  def handle_key(%__MODULE__{autocomplete_active: true} = s, %Key{key: :escape}), do: dismiss_autocomplete(s)

  def handle_key(%__MODULE__{} = s, %Key{key: :enter, modifiers: [:shift]}), do: insert(s, "\n")

  def handle_key(%__MODULE__{} = s, %Key{key: :enter}), do: {s, [{:submit, s.value}]}

  def handle_key(%__MODULE__{cursor: 0} = s, %Key{key: :backspace}), do: s

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :backspace}) do
    s = %{push_undo(s) | last_action: nil}
    {before, after_cursor} = split_at_grapheme(v, c)
    trimmed = before |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{s | value: trimmed <> after_cursor, cursor: c - 1}
  end

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :delete}) do
    if c >= String.length(v) do
      s
    else
      s = %{push_undo(s) | last_action: nil}
      {before, after_cursor} = split_at_grapheme(v, c)
      trimmed = after_cursor |> String.graphemes() |> Enum.drop(1) |> Enum.join()
      %{s | value: before <> trimmed}
    end
  end

  def handle_key(%__MODULE__{cursor: 0} = s, %Key{key: ?w, modifiers: [:ctrl]}), do: s

  def handle_key(%__MODULE__{} = s, %Key{key: ?w, modifiers: [:ctrl]}), do: delete_word_backward(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?u, modifiers: [:ctrl]}) do
    line_start = logical_line_start(s.value, s.cursor)
    if s.cursor == line_start, do: s, else: delete_to_line_start(s)
  end

  def handle_key(%__MODULE__{} = s, %Key{key: ?k, modifiers: [:ctrl]}), do: delete_to_line_end(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?d, modifiers: [:alt]}), do: delete_word_forward(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?y, modifiers: [:ctrl]}), do: yank(s)
  def handle_key(%__MODULE__{} = s, %Key{key: ?y, modifiers: [:alt]}), do: yank_pop(s)

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?b, modifiers: [:alt]}),
    do: %{s | cursor: word_boundary_backward(v, c), last_action: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?f, modifiers: [:alt]}),
    do: %{s | cursor: word_boundary_forward(v, c), last_action: nil}

  def handle_key(%__MODULE__{cursor: c} = s, %Key{key: :left}),
    do: %{s | cursor: max(c - 1, 0), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :right}),
    do: %{s | cursor: min(c + 1, String.length(v)), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :home}),
    do: %{s | cursor: logical_line_start(v, c), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?a, modifiers: [:ctrl]}),
    do: %{s | cursor: logical_line_start(v, c), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :end}),
    do: %{s | cursor: logical_line_end(v, c), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?e, modifiers: [:ctrl]}),
    do: %{s | cursor: logical_line_end(v, c), last_action: nil, preferred_col: nil}

  def handle_key(%__MODULE__{} = s, %Key{key: :up}), do: move_vertical(s, -1)
  def handle_key(%__MODULE__{} = s, %Key{key: :down}), do: move_vertical(s, 1)
  def handle_key(%__MODULE__{} = s, %Key{key: :page_up}), do: move_vertical(s, -@page_size)
  def handle_key(%__MODULE__{} = s, %Key{key: :page_down}), do: move_vertical(s, @page_size)

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  # --- kill ring operations ---

  defp delete_word_backward(%__MODULE__{value: v, cursor: c} = s) do
    was_kill = s.last_action == :kill
    s = push_undo(s)
    boundary = word_boundary_backward(v, c)
    deleted = String.slice(v, boundary, c - boundary)
    {before, _} = split_at_grapheme(v, boundary)
    {_, after_cursor} = split_at_grapheme(v, c)
    s = kill_push(s, deleted, true, was_kill)
    %{s | value: before <> after_cursor, cursor: boundary, last_action: :kill}
  end

  defp delete_word_forward(%__MODULE__{value: v, cursor: c} = s) do
    if c >= String.length(v) do
      s
    else
      was_kill = s.last_action == :kill
      s = push_undo(s)
      boundary = word_boundary_forward(v, c)
      deleted = String.slice(v, c, boundary - c)
      {before, _} = split_at_grapheme(v, c)
      {_, after_boundary} = split_at_grapheme(v, boundary)
      s = kill_push(s, deleted, false, was_kill)
      %{s | value: before <> after_boundary, cursor: c, last_action: :kill}
    end
  end

  defp delete_to_line_start(%__MODULE__{value: v, cursor: c} = s) do
    line_start = logical_line_start(v, c)
    was_kill = s.last_action == :kill
    s = push_undo(s)
    deleted = String.slice(v, line_start, c - line_start)
    {before, _} = split_at_grapheme(v, line_start)
    {_, after_cursor} = split_at_grapheme(v, c)
    s = kill_push(s, deleted, true, was_kill)
    %{s | value: before <> after_cursor, cursor: line_start, last_action: :kill}
  end

  defp delete_to_line_end(%__MODULE__{value: v, cursor: c} = s) do
    line_end = logical_line_end(v, c)

    if c >= line_end do
      if c >= String.length(v) do
        s
      else
        was_kill = s.last_action == :kill
        s = push_undo(s)
        {before, _} = split_at_grapheme(v, c)
        {_, after_nl} = split_at_grapheme(v, c + 1)
        s = kill_push(s, "\n", false, was_kill)
        %{s | value: before <> after_nl, cursor: c, last_action: :kill}
      end
    else
      was_kill = s.last_action == :kill
      s = push_undo(s)
      deleted = String.slice(v, c, line_end - c)
      {before, _} = split_at_grapheme(v, c)
      {_, after_end} = split_at_grapheme(v, line_end)
      s = kill_push(s, deleted, false, was_kill)
      %{s | value: before <> after_end, cursor: c, last_action: :kill}
    end
  end

  defp yank(%__MODULE__{kill_ring: []} = s), do: s

  defp yank(%__MODULE__{kill_ring: [text | _], value: v, cursor: c} = s) do
    s = push_undo(s)
    {before, after_cursor} = split_at_grapheme(v, c)

    %{
      s
      | value: before <> text <> after_cursor,
        cursor: c + String.length(text),
        last_action: :yank
    }
  end

  defp yank_pop(%__MODULE__{last_action: action} = s) when action != :yank, do: s
  defp yank_pop(%__MODULE__{kill_ring: ring} = s) when length(ring) <= 1, do: s

  defp yank_pop(%__MODULE__{kill_ring: [prev_text | _], value: v, cursor: c} = s) do
    s = push_undo(s)
    start = c - String.length(prev_text)
    {before, _} = split_at_grapheme(v, start)
    {_, after_cursor} = split_at_grapheme(v, c)
    s = kill_rotate(s)
    [new_text | _] = s.kill_ring

    %{
      s
      | value: before <> new_text <> after_cursor,
        cursor: start + String.length(new_text),
        last_action: :yank
    }
  end

  # --- kill ring helpers ---

  defp kill_push(%__MODULE__{kill_ring: []} = s, text, _prepend, _accumulate), do: %{s | kill_ring: [text]}

  defp kill_push(%__MODULE__{kill_ring: [head | rest]} = s, text, prepend, true) do
    merged = if prepend, do: text <> head, else: head <> text
    %{s | kill_ring: [merged | rest]}
  end

  defp kill_push(%__MODULE__{} = s, text, _prepend, false), do: %{s | kill_ring: [text | s.kill_ring]}

  defp kill_rotate(%__MODULE__{kill_ring: ring} = s) when length(ring) <= 1, do: s

  defp kill_rotate(%__MODULE__{kill_ring: [head | rest]} = s), do: %{s | kill_ring: rest ++ [head]}

  # --- undo ---

  defp push_undo(%__MODULE__{value: v, cursor: c, undo_stack: stack} = s), do: %{s | undo_stack: [{v, c} | stack]}

  defp undo(%__MODULE__{undo_stack: []} = s), do: s

  defp undo(%__MODULE__{undo_stack: [{v, c} | rest]} = s),
    do: %{s | value: v, cursor: c, undo_stack: rest, last_action: nil}

  # --- word boundaries ---

  defp word_boundary_backward(_value, cursor) when cursor <= 0, do: 0

  defp word_boundary_backward(value, cursor) do
    graphemes = value |> String.slice(0, cursor) |> String.graphemes() |> Enum.reverse()
    cursor - count_backward(graphemes)
  end

  defp count_backward(graphemes) do
    {ws, rest} = count_while(graphemes, &whitespace?/1)

    case rest do
      [] ->
        ws

      [g | _] ->
        pred = if punctuation?(g), do: &punctuation?/1, else: &word_char?/1
        {run, _} = count_while(rest, pred)
        ws + run
    end
  end

  defp word_boundary_forward(value, cursor) do
    len = String.length(value)

    if cursor >= len,
      do: cursor,
      else: cursor + (value |> String.slice(cursor, len) |> String.graphemes() |> count_forward())
  end

  defp count_forward(graphemes) do
    {ws, rest} = count_while(graphemes, &whitespace?/1)

    case rest do
      [] ->
        ws

      [g | _] ->
        pred = if punctuation?(g), do: &punctuation?/1, else: &word_char?/1
        {run, _} = count_while(rest, pred)
        ws + run
    end
  end

  defp count_while([], _pred), do: {0, []}

  defp count_while([h | t] = list, pred) do
    if pred.(h) do
      {n, rest} = count_while(t, pred)
      {n + 1, rest}
    else
      {0, list}
    end
  end

  # --- character classification ---

  defp whitespace?(g), do: String.match?(g, ~r/^\s$/u)
  defp punctuation?(g), do: String.match?(g, ~r/^[\p{P}\p{S}]$/u)
  defp word_char?(g), do: not whitespace?(g) and not punctuation?(g)

  # --- vertical navigation ---

  defp move_vertical(%__MODULE__{value: value, width: width, padding_x: px} = s, delta) do
    {_, _, lw} = layout_width(width, px)
    {cur_row, cur_col} = content_rc(s, lw)
    target_col = s.preferred_col || cur_col
    target_row = cur_row + delta
    total_rows = count_visual_rows(value, lw)

    cond do
      target_row < 0 ->
        history_up(s)

      target_row >= total_rows ->
        history_down(s)

      true ->
        new_cursor = cursor_from_visual(value, lw, target_row, target_col)
        %{s | cursor: new_cursor, last_action: nil, preferred_col: target_col}
    end
  end

  defp count_visual_rows(value, width) do
    value
    |> String.split("\n")
    |> Enum.map(&length(wrap_input(&1, width)))
    |> Enum.sum()
  end

  defp cursor_from_visual(value, width, target_row, target_col) do
    graphemes = String.graphemes(value)
    do_cursor_from_visual(graphemes, width, target_row, target_col, 0, 0, 0)
  end

  defp do_cursor_from_visual([], _width, target_row, _target_col, row, _col, pos) do
    if row == target_row, do: pos, else: pos
  end

  defp do_cursor_from_visual(["\n" | _rest], _width, target_row, _target_col, row, _col, pos) when row == target_row,
    do: pos

  defp do_cursor_from_visual(["\n" | rest], width, target_row, target_col, row, _col, pos) do
    do_cursor_from_visual(rest, width, target_row, target_col, row + 1, 0, pos + 1)
  end

  defp do_cursor_from_visual([g | rest], width, target_row, target_col, row, col, pos) do
    {new_row, new_col} = advance_rc(g, {row, col}, width)

    cond do
      new_row > target_row ->
        pos

      new_row == target_row and new_col > target_col and col <= target_col ->
        pos

      true ->
        do_cursor_from_visual(rest, width, target_row, target_col, new_row, new_col, pos + 1)
    end
  end

  # --- logical line boundaries ---

  defp logical_line_start(value, cursor) do
    before = value |> String.graphemes() |> Enum.take(cursor) |> Enum.join()

    case before |> String.split("\n") |> List.last() do
      nil -> 0
      last_segment -> cursor - String.length(last_segment)
    end
  end

  defp logical_line_end(value, cursor) do
    after_cursor = value |> String.graphemes() |> Enum.drop(cursor) |> Enum.join()

    case :binary.match(after_cursor, "\n") do
      {pos, _} -> cursor + pos
      :nomatch -> String.length(value)
    end
  end

  @doc "Compute scroll offset to keep cursor visible within viewport_height."
  @spec scroll_offset(t(), pos_integer(), pos_integer()) :: non_neg_integer()
  def scroll_offset(%__MODULE__{padding_x: px} = s, width, viewport_height) do
    {_, _, lw} = layout_width(width, px)
    {cursor_row, _} = content_rc(s, lw)
    total_rows = count_visual_rows(s.value, lw)
    scroll_for_cursor(s.scroll_offset, cursor_row, viewport_height, total_rows)
  end

  # --- helpers ---

  defp advance_rc("\n", {row, _col}, _width), do: {row + 1, 0}

  defp advance_rc(g, {row, col}, width) do
    w = WrapAnsi.grapheme_width(g)
    if col > 0 and col + w > width, do: {row + 1, w}, else: {row, col + w}
  end

  defp split_at_grapheme(str, n) do
    graphemes = String.graphemes(str)
    {before, rest} = Enum.split(graphemes, n)
    {Enum.join(before), Enum.join(rest)}
  end

  # --- history ---

  @doc "Add an entry to history, deduplicating consecutive repeats and capping at #{@max_history}."
  @spec push_history(t(), String.t()) :: t()
  def push_history(%__MODULE__{history: history} = s, entry) do
    case_result =
      case List.last(history) do
        ^entry -> history
        _ -> history ++ [entry]
      end

    history = Enum.take(case_result, -@max_history)

    %{s | history: history, history_index: nil, saved_input: nil}
  end

  defp history_up(%__MODULE__{history: []} = s), do: %{s | last_action: nil}

  defp history_up(%__MODULE__{history: history, history_index: nil} = s) do
    idx = length(history) - 1
    entry = Enum.at(history, idx)

    %{
      s
      | value: entry,
        cursor: String.length(entry),
        history_index: idx,
        saved_input: s.value,
        last_action: nil
    }
  end

  defp history_up(%__MODULE__{history: history, history_index: idx} = s) do
    new_idx = max(idx - 1, 0)
    entry = Enum.at(history, new_idx)
    %{s | value: entry, cursor: String.length(entry), history_index: new_idx, last_action: nil}
  end

  defp history_down(%__MODULE__{history_index: nil} = s), do: %{s | last_action: nil}

  defp history_down(%__MODULE__{history: history, history_index: idx} = s) do
    new_idx = idx + 1

    if new_idx >= length(history) do
      restored = s.saved_input || ""

      %{
        s
        | value: restored,
          cursor: String.length(restored),
          history_index: nil,
          saved_input: nil,
          last_action: nil
      }
    else
      entry = Enum.at(history, new_idx)
      %{s | value: entry, cursor: String.length(entry), history_index: new_idx, last_action: nil}
    end
  end

  # --- autocomplete ---

  @doc "Render autocomplete dropdown lines. Returns [] when inactive."
  @spec render_dropdown(t(), pos_integer()) :: [String.t()]
  def render_dropdown(%__MODULE__{autocomplete_active: false}, _width), do: []

  def render_dropdown(%__MODULE__{autocomplete_suggestions: suggestions, autocomplete_selected: sel}, width) do
    suggestions
    |> Enum.with_index()
    |> Enum.map(fn {%Suggestion{label: label, description: desc}, idx} ->
      text = format_suggestion(label, desc, width)
      if idx == sel, do: "\e[7m#{text}\e[27m", else: "  #{text}"
    end)
  end

  defp format_suggestion(label, nil, _max_width), do: label

  defp format_suggestion(label, desc, max_width) do
    combined = "#{label}  #{desc}"

    if String.length(combined) > max_width,
      do: String.slice(combined, 0, max_width),
      else: combined
  end

  defp refresh_autocomplete(%__MODULE__{autocomplete_provider: nil} = s), do: s

  defp refresh_autocomplete(%__MODULE__{value: value, autocomplete_provider: provider} = s) do
    {:ok, suggestions} = Autocomplete.get_suggestions(provider, value)

    case suggestions do
      [] ->
        %{s | autocomplete_active: false, autocomplete_suggestions: [], autocomplete_selected: 0}

      _ ->
        %{
          s
          | autocomplete_active: true,
            autocomplete_suggestions: suggestions,
            autocomplete_selected: 0
        }
    end
  end

  defp autocomplete_navigate(%__MODULE__{autocomplete_suggestions: suggestions, autocomplete_selected: sel} = s, delta) do
    len = length(suggestions)
    new_sel = rem(sel + delta + len, len)
    %{s | autocomplete_selected: new_sel}
  end

  defp autocomplete_accept(%__MODULE__{autocomplete_suggestions: suggestions, autocomplete_selected: sel} = s) do
    case Enum.at(suggestions, sel) do
      nil ->
        s

      %Suggestion{value: value} ->
        dismiss_autocomplete(%{s | value: value, cursor: String.length(value)})
    end
  end

  defp dismiss_autocomplete(%__MODULE__{} = s) do
    %{s | autocomplete_active: false, autocomplete_suggestions: [], autocomplete_selected: 0}
  end

  defp scroll_for_cursor(current_offset, cursor_row, max_visible, total) do
    offset =
      cond do
        total <= max_visible -> 0
        cursor_row < current_offset -> cursor_row
        cursor_row >= current_offset + max_visible -> cursor_row - max_visible + 1
        true -> current_offset
      end

    max_offset = max(0, total - max_visible)
    min(offset, max_offset)
  end

  defp border_line(nil, width), do: String.duplicate("─", width)

  defp border_line(theme, width) do
    Theme.fg(theme, :border_muted, String.duplicate("─", width))
  end

  defp scroll_border(theme, width, _direction, 0), do: border_line(theme, width)

  defp scroll_border(theme, width, direction, count) do
    arrow = if direction == :up, do: "↑", else: "↓"
    indicator = "─── #{arrow} #{count} more "
    indicator_width = WrapAnsi.visible_width(indicator)
    remaining = max(0, width - indicator_width)
    line = indicator <> String.duplicate("─", remaining)

    case theme do
      nil -> line
      _ -> Theme.fg(theme, :border_muted, line)
    end
  end

  # --- visible cursor injection ---

  defp inject_cursor(lines, row, col) do
    List.update_at(lines, row, &inject_cursor_at(&1, col))
  end

  defp inject_cursor_at(line, col) do
    graphemes = String.graphemes(line)
    {before, at_and_after} = split_at_display_col(graphemes, col, 0, [])

    case at_and_after do
      [] -> before <> @reverse_on <> " " <> @reverse_off
      [g | rest] -> before <> @reverse_on <> g <> @reverse_off <> Enum.join(rest)
    end
  end

  defp split_at_display_col(rest, target, current, acc) when current >= target,
    do: {acc |> Enum.reverse() |> Enum.join(), rest}

  defp split_at_display_col([], _target, _current, acc), do: {acc |> Enum.reverse() |> Enum.join(), []}

  defp split_at_display_col([g | rest], target, current, acc),
    do: split_at_display_col(rest, target, current + WrapAnsi.grapheme_width(g), [g | acc])

  defp wrap_input(value, width) do
    value
    |> String.graphemes()
    |> Enum.reduce({[""], 0}, fn g, {[line | rest], col} ->
      w = WrapAnsi.grapheme_width(g)

      if col > 0 and col + w > width do
        {[g, line | rest], w}
      else
        {[line <> g | rest], col + w}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end
end
