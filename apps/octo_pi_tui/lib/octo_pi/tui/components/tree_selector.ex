defmodule OctoPi.TUI.Components.TreeSelector do
  @moduledoc """
  Interactive tree selector component. G5b — keybinds + selection state +
  filter cycling on top of the G5a pure-functional tree renderer
  (`OctoPi.Coder.Components.TreeSelector`).

  `handle_key/2` returns `{updated_state, events}` where events may contain:
    * `{:select, entry_id}` — user confirmed a selection
    * `:cancel`             — user cancelled

  ## Filter cycling

  Modes cycle in order: `:default → :no_tools → :user_only → :labeled_only → :all`.
  Direct-mode keys toggle between their mode and `:default`; cycle keys walk the
  ring forward or backward.

  ## Keybindings used

  | Action                       | Default key      |
  |------------------------------|------------------|
  | `tui.select.up`              | up               |
  | `tui.select.down`            | down             |
  | `tui.select.pageUp`          | page_up          |
  | `tui.select.pageDown`        | page_down        |
  | `tui.select.confirm`         | enter            |
  | `tui.select.cancel`          | escape / ctrl+c  |
  | `app.tree.filter.default`    | ctrl+d           |
  | `app.tree.filter.noTools`    | ctrl+t           |
  | `app.tree.filter.userOnly`   | ctrl+u           |
  | `app.tree.filter.labeledOnly`| ctrl+l           |
  | `app.tree.filter.all`        | ctrl+a           |
  | `app.tree.filter.cycleForward`  | ctrl+o        |
  | `app.tree.filter.cycleBackward` | shift+ctrl+o  |
  """

  alias OctoPi.Coder.Components.TreeSelector, as: Tree
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings

  @filter_cycle [:default, :no_tools, :user_only, :labeled_only, :all]

  @type t :: %__MODULE__{
          entries: [Entry.t()],
          leaf_id: String.t() | nil,
          keybindings: Keybindings.t(),
          filter_mode: Tree.filter_mode(),
          selected_index: non_neg_integer(),
          flat_nodes: [Tree.FlatNode.t()],
          filtered_nodes: [Tree.FlatNode.t()],
          max_visible_lines: pos_integer()
        }

  defstruct [
    :entries,
    :leaf_id,
    :keybindings,
    filter_mode: :default,
    selected_index: 0,
    flat_nodes: [],
    filtered_nodes: [],
    max_visible_lines: 20
  ]

  @doc """
  Build a `TreeSelector` from a flat list of entries.

  Options:
    * `:leaf_id`            — mark the current active leaf
    * `:initial_filter`     — initial `filter_mode` (default: `:default`)
    * `:initial_selected_id`— entry id to pre-select
    * `:max_visible_lines`  — page size for page up/down (default: 20)
    * `:keybindings`        — `Keybindings.t()` (default: `Keybindings.new()`)
  """
  @spec new([Entry.t()], keyword()) :: t()
  def new(entries, opts \\ []) do
    leaf_id = Keyword.get(opts, :leaf_id)
    filter = Keyword.get(opts, :initial_filter, :default)
    initial_id = Keyword.get(opts, :initial_selected_id, leaf_id)
    kb = Keyword.get(opts, :keybindings, Keybindings.new())
    max_lines = Keyword.get(opts, :max_visible_lines, 20)

    roots = Tree.build_tree(entries)
    flat = Tree.flatten(roots, leaf_id)
    filtered = Tree.filter(flat, filter, leaf_id)
    idx = find_nearest_visible_index(filtered, flat, initial_id)

    %__MODULE__{
      entries: entries,
      leaf_id: leaf_id,
      keybindings: kb,
      filter_mode: filter,
      selected_index: idx,
      flat_nodes: flat,
      filtered_nodes: filtered,
      max_visible_lines: max_lines
    }
  end

  @doc "Return the id of the currently selected entry, or `nil` if empty."
  @spec selected_id(t()) :: String.t() | nil
  def selected_id(%__MODULE__{filtered_nodes: nodes, selected_index: idx}) do
    case Enum.at(nodes, idx) do
      nil -> nil
      flat_node -> flat_node.node.entry.id
    end
  end

  def render(%__MODULE__{} = state, _width) do
    Tree.render_lines(state.filtered_nodes,
      leaf_id: state.leaf_id,
      selected_id: selected_id(state)
    )
  end

  def handle_key(%__MODULE__{} = state, %Key{} = key) do
    kb = state.keybindings

    cond do
      Keybindings.matches?(kb, key, "tui.select.up") -> {move_cursor(state, -1), []}
      Keybindings.matches?(kb, key, "tui.select.down") -> {move_cursor(state, +1), []}
      Keybindings.matches?(kb, key, "tui.select.pageUp") -> {move_cursor(state, -state.max_visible_lines), []}
      Keybindings.matches?(kb, key, "tui.select.pageDown") -> {move_cursor(state, +state.max_visible_lines), []}
      Keybindings.matches?(kb, key, "tui.select.confirm") -> handle_confirm(state)
      Keybindings.matches?(kb, key, "tui.select.cancel") -> {state, [:cancel]}
      true -> handle_filter_key(state, kb, key)
    end
  end

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  defp handle_confirm(state) do
    case selected_id(state) do
      nil -> {state, []}
      id -> {state, [{:select, id}]}
    end
  end

  defp handle_filter_key(state, kb, key) do
    cond do
      Keybindings.matches?(kb, key, "app.tree.filter.cycleForward") ->
        {set_filter(state, cycle_filter(state.filter_mode, +1)), []}

      Keybindings.matches?(kb, key, "app.tree.filter.cycleBackward") ->
        {set_filter(state, cycle_filter(state.filter_mode, -1)), []}

      Keybindings.matches?(kb, key, "app.tree.filter.default") ->
        {set_filter(state, :default), []}

      Keybindings.matches?(kb, key, "app.tree.filter.noTools") ->
        {set_filter(state, toggle_filter(state.filter_mode, :no_tools)), []}

      Keybindings.matches?(kb, key, "app.tree.filter.userOnly") ->
        {set_filter(state, toggle_filter(state.filter_mode, :user_only)), []}

      Keybindings.matches?(kb, key, "app.tree.filter.labeledOnly") ->
        {set_filter(state, toggle_filter(state.filter_mode, :labeled_only)), []}

      Keybindings.matches?(kb, key, "app.tree.filter.all") ->
        {set_filter(state, toggle_filter(state.filter_mode, :all)), []}

      true ->
        {state, []}
    end
  end

  # ── private ───────────────────────────────────────────────────────────────

  defp move_cursor(%__MODULE__{filtered_nodes: []} = state, _delta), do: state

  defp move_cursor(%__MODULE__{selected_index: idx, filtered_nodes: nodes} = state, delta) do
    count = length(nodes)
    new_idx = (idx + delta) |> max(0) |> min(count - 1)
    %{state | selected_index: new_idx}
  end

  defp set_filter(%__MODULE__{} = state, new_mode) do
    filtered = Tree.filter(state.flat_nodes, new_mode, state.leaf_id)
    idx = preserve_or_find(state, filtered)
    %{state | filter_mode: new_mode, filtered_nodes: filtered, selected_index: idx}
  end

  defp preserve_or_find(%__MODULE__{} = state, new_filtered) do
    current_id = selected_id(state)
    find_nearest_visible_index(new_filtered, state.flat_nodes, current_id)
  end

  defp toggle_filter(current, mode) when current == mode, do: :default
  defp toggle_filter(_current, mode), do: mode

  defp cycle_filter(current, delta) do
    idx = Enum.find_index(@filter_cycle, &(&1 == current)) || 0
    count = length(@filter_cycle)
    Enum.at(@filter_cycle, rem(idx + delta + count, count))
  end

  defp find_nearest_visible_index([], _flat, _id), do: 0
  defp find_nearest_visible_index(filtered, _flat, nil), do: max(0, length(filtered) - 1)

  defp find_nearest_visible_index(filtered, flat, target_id) do
    visible_id_to_idx =
      filtered
      |> Enum.with_index()
      |> Map.new(fn {fn_node, i} -> {fn_node.node.entry.id, i} end)

    parent_map = Map.new(flat, fn fn_node -> {fn_node.node.entry.id, fn_node.node.entry.parent_id} end)

    walk_to_visible(target_id, visible_id_to_idx, parent_map, length(filtered) - 1)
  end

  defp walk_to_visible(nil, _visible, _parent, fallback), do: fallback

  defp walk_to_visible(id, visible, parent, fallback) do
    case Map.get(visible, id) do
      nil ->
        parent_id = Map.get(parent, id)
        walk_to_visible(parent_id, visible, parent, fallback)

      idx ->
        idx
    end
  end
end
