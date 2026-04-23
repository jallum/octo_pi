defmodule OctoPi.TUI.Components.SelectList do
  @moduledoc """
  Selectable list. Renders each item on its own line; the selected
  item is marked with a prefix (default `"> "`) and reverse-video
  styling.

  Keys: Up/Down (wraps), Enter submits the selected item. Fuzzy
  filter, custom truncation, and multi-column alignment are
  deferred to Phase 4.1 — MVP is a plain list with arrow keys.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key

  @type t :: %__MODULE__{
          items: [String.t()],
          selected: non_neg_integer(),
          prefix: String.t()
        }

  @enforce_keys [:items]
  defstruct items: [], selected: 0, prefix: "> "

  # --- render ---

  @impl true
  def render(%__MODULE__{items: []}, _width), do: ["(empty)"]

  def render(%__MODULE__{items: items, selected: sel, prefix: prefix}, width) do
    pad = String.duplicate(" ", String.length(prefix))

    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} -> render_item(item, idx == sel, prefix, pad, width) end)
  end

  defp render_item(item, true, prefix, _pad, width),
    do: truncate("\e[7m#{prefix}#{item}\e[27m", width)

  defp render_item(item, false, _prefix, pad, width),
    do: truncate("#{pad}#{item}", width)

  # --- handle_key: multi-head dispatch ---

  @impl true
  def handle_key(%__MODULE__{items: []} = s, _), do: s

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :up}),
    do: %{s | selected: wrap(sel - 1, length(items))}

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :down}),
    do: %{s | selected: wrap(sel + 1, length(items))}

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :enter}),
    do: {s, [{:select, Enum.at(items, sel)}]}

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  # --- helpers ---

  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx

  defp truncate(line, width) when byte_size(line) <= width, do: line
  defp truncate(line, width), do: String.slice(line, 0, width)
end
