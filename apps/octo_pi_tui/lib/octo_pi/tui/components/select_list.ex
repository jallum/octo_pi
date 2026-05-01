defmodule OctoPi.TUI.Components.SelectList do
  @moduledoc """
  Selectable list with optional two-column label/description layout.

  Items may be plain strings (auto-wrapped into value == label ==
  string, description == nil) or `%SelectList.Item{value, label,
  description}` structs. When any item has a description, render/2
  emits a two-column layout:

      <prefix><label>        <description>

  The primary column width is clamped to `min_primary_column_width`
  and `max_primary_column_width`; labels wider than the effective
  primary width are truncated via the configurable `truncate_primary`
  hook (default: `WrapAnsi.truncate_to_width/4` with "..."). The
  description column starts at the same absolute visible column on
  every row, preserving alignment even when a label was truncated.

  Multiline descriptions are normalized to a single line (newlines
  become spaces) so one item maps to one rendered row.

  Keys: Up/Down (wraps), Enter submits the selected item's value,
  Escape cancels.
  """

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.WrapAnsi

  defmodule Item do
    @moduledoc "Entry in a SelectList — value surfaces on submit, label + optional description render."
    defstruct [:value, :label, description: nil]

    @type t :: %__MODULE__{value: any(), label: String.t(), description: String.t() | nil}
  end

  @type item_input :: String.t() | Item.t()
  @type truncate_fun :: (%{text: String.t(), max_width: non_neg_integer()} -> String.t())

  @type t :: %__MODULE__{
          items: [item_input()],
          selected: non_neg_integer(),
          prefix: String.t(),
          min_primary_column_width: non_neg_integer(),
          max_primary_column_width: non_neg_integer(),
          truncate_primary: truncate_fun() | nil
        }

  @enforce_keys [:items]
  defstruct items: [],
            selected: 0,
            prefix: "> ",
            min_primary_column_width: 0,
            max_primary_column_width: 4096,
            truncate_primary: nil

  # --- render ---

  def render(%__MODULE__{items: []}, _width), do: ["(empty)"]

  def render(%__MODULE__{} = state, width) do
    items = Enum.map(state.items, &normalize_item/1)

    if Enum.any?(items, &(&1.description not in [nil, ""])) do
      render_two_column(state, items, width)
    else
      render_single_column(state, items, width)
    end
  end

  defp render_single_column(%__MODULE__{selected: sel, prefix: prefix}, items, width) do
    pad = String.duplicate(" ", String.length(prefix))

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      render_line(item.label, idx == sel, prefix, pad, width)
    end)
  end

  @primary_column_gap 2

  defp render_two_column(%__MODULE__{} = state, items, width) do
    prefix_w = String.length(state.prefix)
    pad = String.duplicate(" ", prefix_w)

    natural =
      items
      |> Enum.map(&(WrapAnsi.visible_width(&1.label) + @primary_column_gap))
      |> Enum.max(fn -> 0 end)

    primary_w =
      natural
      |> max(state.min_primary_column_width)
      |> min(state.max_primary_column_width)

    max_primary_w = max(1, primary_w - @primary_column_gap)
    trunc_fn = state.truncate_primary || (&default_truncate/1)

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      truncated = trunc_fn.(%{text: item.label, max_width: max_primary_w})
      spacing = pad_to_width(truncated, primary_w)
      description = normalize_description(item.description)

      line =
        if idx == state.selected do
          "\e[7m#{state.prefix}#{truncated}\e[27m#{spacing}#{description}"
        else
          "#{pad}#{truncated}#{spacing}#{description}"
        end

      truncate_line(line, width)
    end)
  end

  defp render_line(item, true, prefix, _pad, width), do: truncate_line("\e[7m#{prefix}#{item}\e[27m", width)

  defp render_line(item, false, _prefix, pad, width), do: truncate_line("#{pad}#{item}", width)

  defp normalize_item(%Item{} = item), do: item
  defp normalize_item(s) when is_binary(s), do: %Item{value: s, label: s, description: nil}

  defp normalize_description(nil), do: ""
  defp normalize_description(""), do: ""
  defp normalize_description(desc), do: String.replace(desc, "\n", " ")

  defp pad_to_width(text, width) do
    actual = WrapAnsi.visible_width(text)
    if actual >= width, do: "", else: String.duplicate(" ", width - actual)
  end

  defp default_truncate(%{text: text, max_width: max_w}) do
    if WrapAnsi.visible_width(text) <= max_w do
      text
    else
      WrapAnsi.truncate_to_width(text, max_w, "...", false)
    end
  end

  defp truncate_line(line, width) do
    if WrapAnsi.visible_width(line) <= width,
      do: line,
      else: WrapAnsi.truncate_to_width(line, width, "", false)
  end

  # --- handle_key: multi-head dispatch ---

  def handle_key(%__MODULE__{items: []} = s, _), do: s

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :up}),
    do: %{s | selected: wrap(sel - 1, length(items))}

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :down}),
    do: %{s | selected: wrap(sel + 1, length(items))}

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :enter}) do
    value = items |> Enum.at(sel) |> normalize_item() |> Map.get(:value)
    {s, [{:select, value}]}
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  # --- helpers ---

  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
