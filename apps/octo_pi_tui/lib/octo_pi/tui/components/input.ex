defmodule OctoPi.TUI.Components.Input do
  @moduledoc """
  Editable text input with display-width-aware wrapping, Emacs-style
  kill ring, undo stack, and word-boundary navigation.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.{Key, WrapAnsi}

  @type t :: %__MODULE__{
          value: String.t(),
          cursor: non_neg_integer(),
          kill_ring: [String.t()],
          last_action: :kill | :yank | :type_word | nil,
          undo_stack: [{String.t(), non_neg_integer()}]
        }

  defstruct value: "",
            cursor: 0,
            kill_ring: [],
            last_action: nil,
            undo_stack: []

  # --- render ---

  @impl true
  def render(%__MODULE__{value: value}, width), do: wrap_input(value, width)

  @doc "Cursor position within the wrapped output as `{row, col}` (0-indexed, display-width columns)."
  @spec cursor_rc(t(), pos_integer()) :: {non_neg_integer(), non_neg_integer()}
  def cursor_rc(%__MODULE__{value: value, cursor: cursor}, width) do
    {row, col} =
      value
      |> String.graphemes()
      |> Enum.take(cursor)
      |> Enum.reduce({0, 0}, fn g, {row, col} ->
        w = WrapAnsi.grapheme_width(g)

        if col > 0 and col + w > width do
          {row + 1, w}
        else
          {row, col + w}
        end
      end)

    if col >= width, do: {row + 1, 0}, else: {row, col}
  end

  # --- public API ---

  @doc "Set the value, clamping cursor. Preserves kill ring, undo, etc."
  @spec set_value(t(), String.t()) :: t()
  def set_value(%__MODULE__{cursor: c} = s, value),
    do: %{s | value: value, cursor: min(c, String.length(value))}

  @doc "Insert a char at the cursor (from KeyParser {:char, _} events)."
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{value: v, cursor: c} = s, char) do
    s = if whitespace?(char) or s.last_action != :type_word, do: push_undo(s), else: s
    {before, after_cursor} = split_at_grapheme(v, c)

    %{
      s
      | value: before <> char <> after_cursor,
        cursor: c + String.length(char),
        last_action: :type_word
    }
  end

  @doc "Insert pasted text atomically (single undo unit)."
  @spec paste(t(), String.t()) :: t()
  def paste(%__MODULE__{value: v, cursor: c} = s, text) do
    clean =
      text
      |> String.replace("\r\n", "")
      |> String.replace("\r", "")
      |> String.replace("\n", "")
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

  def handle_key(%__MODULE__{} = s, %Key{key: ?w, modifiers: [:ctrl]}),
    do: delete_word_backward(s)

  def handle_key(%__MODULE__{cursor: 0} = s, %Key{key: ?u, modifiers: [:ctrl]}), do: s

  def handle_key(%__MODULE__{} = s, %Key{key: ?u, modifiers: [:ctrl]}),
    do: delete_to_line_start(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?k, modifiers: [:ctrl]}), do: delete_to_line_end(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?d, modifiers: [:alt]}), do: delete_word_forward(s)

  def handle_key(%__MODULE__{} = s, %Key{key: ?y, modifiers: [:ctrl]}), do: yank(s)
  def handle_key(%__MODULE__{} = s, %Key{key: ?y, modifiers: [:alt]}), do: yank_pop(s)

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?b, modifiers: [:alt]}),
    do: %{s | cursor: word_boundary_backward(v, c), last_action: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: ?f, modifiers: [:alt]}),
    do: %{s | cursor: word_boundary_forward(v, c), last_action: nil}

  def handle_key(%__MODULE__{cursor: c} = s, %Key{key: :left}),
    do: %{s | cursor: max(c - 1, 0), last_action: nil}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :right}),
    do: %{s | cursor: min(c + 1, String.length(v)), last_action: nil}

  def handle_key(%__MODULE__{} = s, %Key{key: :home}),
    do: %{s | cursor: 0, last_action: nil}

  def handle_key(%__MODULE__{} = s, %Key{key: ?a, modifiers: [:ctrl]}),
    do: %{s | cursor: 0, last_action: nil}

  def handle_key(%__MODULE__{value: v} = s, %Key{key: :end}),
    do: %{s | cursor: String.length(v), last_action: nil}

  def handle_key(%__MODULE__{value: v} = s, %Key{key: ?e, modifiers: [:ctrl]}),
    do: %{s | cursor: String.length(v), last_action: nil}

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
    was_kill = s.last_action == :kill
    s = push_undo(s)
    deleted = String.slice(v, 0, c)
    {_, after_cursor} = split_at_grapheme(v, c)
    s = kill_push(s, deleted, true, was_kill)
    %{s | value: after_cursor, cursor: 0, last_action: :kill}
  end

  defp delete_to_line_end(%__MODULE__{value: v, cursor: c} = s) do
    if c >= String.length(v) do
      s
    else
      was_kill = s.last_action == :kill
      s = push_undo(s)
      deleted = String.slice(v, c, String.length(v) - c)
      {before, _} = split_at_grapheme(v, c)
      s = kill_push(s, deleted, false, was_kill)
      %{s | value: before, cursor: c, last_action: :kill}
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

  defp kill_push(%__MODULE__{kill_ring: []} = s, text, _prepend, _accumulate),
    do: %{s | kill_ring: [text]}

  defp kill_push(%__MODULE__{kill_ring: [head | rest]} = s, text, prepend, true) do
    merged = if prepend, do: text <> head, else: head <> text
    %{s | kill_ring: [merged | rest]}
  end

  defp kill_push(%__MODULE__{} = s, text, _prepend, false),
    do: %{s | kill_ring: [text | s.kill_ring]}

  defp kill_rotate(%__MODULE__{kill_ring: ring} = s) when length(ring) <= 1, do: s

  defp kill_rotate(%__MODULE__{kill_ring: [head | rest]} = s),
    do: %{s | kill_ring: rest ++ [head]}

  # --- undo ---

  defp push_undo(%__MODULE__{value: v, cursor: c, undo_stack: stack} = s),
    do: %{s | undo_stack: [{v, c} | stack]}

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
      else: cursor + count_forward(value |> String.slice(cursor, len) |> String.graphemes())
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

  # --- helpers ---

  defp split_at_grapheme(str, n) do
    graphemes = String.graphemes(str)
    {before, rest} = Enum.split(graphemes, n)
    {Enum.join(before), Enum.join(rest)}
  end

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
