defmodule OctoPi.TUI.Components.Input do
  @moduledoc """
  Single-line editable input. Holds a value, cursor position,
  and focus flag. `handle_key/2` dispatches on the key struct via
  multi-head pattern matching — one clause per key we recognize,
  a fallback for printable chars.

  Emits `{:submit, value}` events when Enter is pressed and the
  input is focused.

  Deferred to the Editor component / Phase 4.1:
    * multi-line input
    * kill ring (Ctrl+W/U/K/Alt+D/Alt+Y)
    * undo/redo stack
    * slash/file autocomplete
    * history navigation
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key

  @type t :: %__MODULE__{
          value: String.t(),
          cursor: non_neg_integer(),
          focused: boolean()
        }

  defstruct value: "", cursor: 0, focused: true

  # --- render ---
  #
  # Render just the value as a single line. The terminal's own
  # hardware cursor (positioned by the Interactive loop after the
  # renderer flush) marks the insertion point — no painted block.
  # This matches upstream's approach and avoids the "fat cursor"
  # artifact you'd see from a reverse-video marker on every
  # render.

  @impl true
  def render(%__MODULE__{value: value}, width), do: [truncate(value, width)]

  # --- handle_key: multi-head dispatch, one clause per key ---

  @impl true
  def handle_key(%__MODULE__{focused: false} = s, _), do: s

  def handle_key(%__MODULE__{} = s, %Key{key: :enter}), do: {s, [{:submit, s.value}]}

  def handle_key(%__MODULE__{cursor: c} = s, %Key{key: :left}),
    do: %{s | cursor: max(c - 1, 0)}

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :right}),
    do: %{s | cursor: min(c + 1, String.length(v))}

  # Home: Ctrl+A or dedicated :home key.
  def handle_key(%__MODULE__{} = s, %Key{key: :home}), do: %{s | cursor: 0}

  def handle_key(%__MODULE__{} = s, %Key{key: ?a, modifiers: [:ctrl]}),
    do: %{s | cursor: 0}

  # End: Ctrl+E or dedicated :end key.
  def handle_key(%__MODULE__{value: v} = s, %Key{key: :end}),
    do: %{s | cursor: String.length(v)}

  def handle_key(%__MODULE__{value: v} = s, %Key{key: ?e, modifiers: [:ctrl]}),
    do: %{s | cursor: String.length(v)}

  # Backspace: delete grapheme before cursor.
  def handle_key(%__MODULE__{cursor: 0} = s, %Key{key: :backspace}), do: s

  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :backspace}) do
    {before, after_cursor} = split_at_grapheme(v, c)
    before_trimmed = before |> String.graphemes() |> Enum.drop(-1) |> Enum.join()
    %{s | value: before_trimmed <> after_cursor, cursor: c - 1}
  end

  # Delete: delete grapheme at cursor.
  def handle_key(%__MODULE__{value: v, cursor: c} = s, %Key{key: :delete}) do
    {before, after_cursor} = split_at_grapheme(v, c)
    after_trimmed = after_cursor |> String.graphemes() |> Enum.drop(1) |> Enum.join()
    %{s | value: before <> after_trimmed}
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  # Anything else: unchanged.
  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  # --- convenience entry point for printable chars ---

  @doc "Insert a char (from `KeyParser.parse/1` `{:char, _}` result) at the cursor."
  @spec insert(t(), String.t()) :: t()
  def insert(%__MODULE__{focused: false} = s, _), do: s

  def insert(%__MODULE__{value: v, cursor: c} = s, char) do
    {before, after_cursor} = split_at_grapheme(v, c)
    %{s | value: before <> char <> after_cursor, cursor: c + String.length(char)}
  end

  # --- helpers ---

  defp split_at_grapheme(str, n) do
    graphemes = String.graphemes(str)
    {before, rest} = Enum.split(graphemes, n)
    {Enum.join(before), Enum.join(rest)}
  end

  defp first_grapheme(""), do: {" ", ""}

  defp first_grapheme(str) do
    [first | rest] = String.graphemes(str)
    {first, Enum.join(rest)}
  end

  defp truncate(line, width) when byte_size(line) <= width, do: line
  defp truncate(line, width), do: String.slice(line, 0, width)
end
