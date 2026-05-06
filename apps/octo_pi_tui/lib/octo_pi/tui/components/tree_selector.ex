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
  alias OctoPi.Coder.Session.TreeNode
  alias OctoPi.TUI.Components.Input
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
          visible_nodes: [Tree.FlatNode.t()],
          folded_nodes: MapSet.t(),
          max_visible_lines: pos_integer(),
          show_label_timestamps: boolean(),
          label_input: {String.t(), Input.t()} | nil
        }

  defstruct [
    :entries,
    :leaf_id,
    :keybindings,
    filter_mode: :default,
    selected_index: 0,
    flat_nodes: [],
    filtered_nodes: [],
    visible_nodes: [],
    folded_nodes: MapSet.new(),
    max_visible_lines: 20,
    show_label_timestamps: false,
    label_input: nil
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
      visible_nodes: filtered,
      folded_nodes: MapSet.new(),
      max_visible_lines: max_lines
    }
  end

  @doc """
  Build a `TreeSelector` from a pre-built forest of `TreeNode` structs
  (e.g. from `Coder.get_tree/1`). Labels are already resolved on the
  nodes — no `build_tree/1` call needed.

  Accepts the same options as `new/2` except `:initial_filter` is not
  yet supported (defaults to `:default`).
  """
  @spec new_from_tree([TreeNode.t()], keyword()) :: t()
  def new_from_tree(roots, opts \\ []) do
    leaf_id = Keyword.get(opts, :leaf_id)
    filter = Keyword.get(opts, :initial_filter, :default)
    initial_id = Keyword.get(opts, :initial_selected_id, leaf_id)
    kb = Keyword.get(opts, :keybindings, Keybindings.new())
    max_lines = Keyword.get(opts, :max_visible_lines, 20)

    flat = Tree.flatten(roots, leaf_id)
    filtered = Tree.filter(flat, filter, leaf_id)
    idx = find_nearest_visible_index(filtered, flat, initial_id)

    %__MODULE__{
      entries: [],
      leaf_id: leaf_id,
      keybindings: kb,
      filter_mode: filter,
      selected_index: idx,
      flat_nodes: flat,
      filtered_nodes: filtered,
      visible_nodes: filtered,
      folded_nodes: MapSet.new(),
      max_visible_lines: max_lines
    }
  end

  @doc "Return the id of the currently selected entry, or `nil` if empty."
  @spec selected_id(t()) :: String.t() | nil
  def selected_id(%__MODULE__{visible_nodes: nodes, selected_index: idx}) do
    case Enum.at(nodes, idx) do
      nil -> nil
      flat_node -> flat_node.node.entry.id
    end
  end

  def render(%__MODULE__{label_input: {_entry_id, input}}, width) do
    input_lines = Input.render(%{input | width: max(1, width - 2), height: 1}, width - 2)

    [
      header_line("Session Tree", width),
      "↑/↓: move. ←/→: page. ^←/^→ or Alt+←/Alt+→: fold/branch",
      "  Label (empty to remove):"
    ] ++ Enum.map(input_lines, &("  " <> &1)) ++ ["  enter: save   escape: cancel"]
  end

  def render(%__MODULE__{} = state, width) do
    total = length(state.visible_nodes)

    window_start = max(
      0,
      min(
        state.selected_index - div(state.max_visible_lines, 2),
        total - state.max_visible_lines
      )
    )

    window_end = min(window_start + state.max_visible_lines, total)

    window_nodes = Enum.slice(state.visible_nodes, window_start, window_end - window_start)

    tree_lines = Tree.render_lines(window_nodes,
      leaf_id: state.leaf_id,
      selected_id: selected_id(state),
      ansi: true,
      show_label_timestamps: state.show_label_timestamps,
      folded_ids: state.folded_nodes,
      width: width
    )

    status_suffix = if state.show_label_timestamps, do: " [+label time]", else: ""
    count_badge = "(#{state.selected_index + 1}/#{total})#{status_suffix}"

    count_line = String.pad_leading(count_badge, width, " ")

    [
      header_line("Session Tree", width),
      "↑/↓: move. ←/→: page. ^←/^→ or Alt+←/Alt+→: fold/branch",
      "Type to search:" | tree_lines
    ] ++ [String.duplicate("─", width), count_line]
  end

  defp header_line(title, width) do
    prefix = "─── " <> title <> " "
    String.duplicate("─", max(0, width - String.length(prefix))) |> then(&(prefix <> &1))
  end

  def handle_key(%__MODULE__{label_input: {entry_id, input}} = state, %Key{} = key) do
    case Input.handle_key(input, key, state.keybindings) do
      {_new_input, [{:submit, value}]} ->
        label = value |> String.trim() |> then(fn s -> if s == "", do: nil, else: s end)
        ts = if label, do: DateTime.to_iso8601(DateTime.utc_now()), else: nil
        new_state =
          state
          |> Map.put(:label_input, nil)
          |> update_flat_node_label(entry_id, label, ts)
        {new_state, [{:label_change, entry_id, label}]}

      {_new_input, [:cancel]} ->
        {%{state | label_input: nil}, []}

      new_input when is_struct(new_input, Input) ->
        {%{state | label_input: {entry_id, new_input}}, []}

      {new_input, _events} ->
        {%{state | label_input: {entry_id, new_input}}, []}
    end
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
      Keybindings.matches?(kb, key, "app.tree.toggleLabelTimestamp") ->
        {%{state | show_label_timestamps: not state.show_label_timestamps}, []}
      Keybindings.matches?(kb, key, "app.tree.editLabel") ->
        open_label_input(state)
      Keybindings.matches?(kb, key, "app.tree.foldOrUp") ->
        {handle_fold_or_up(state), []}
      Keybindings.matches?(kb, key, "app.tree.unfoldOrDown") ->
        {handle_unfold_or_down(state), []}
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

  defp open_label_input(state) do
    case selected_id(state) do
      nil ->
        {state, []}

      entry_id ->
        current_label =
          case Enum.find(state.flat_nodes, fn fn_node -> fn_node.node.entry.id == entry_id end) do
            nil -> ""
            fn_node -> fn_node.node.label || ""
          end

        input = %Input{value: current_label, cursor: String.length(current_label)}
        {%{state | label_input: {entry_id, input}}, []}
    end
  end

  defp update_flat_node_label(state, entry_id, label, label_timestamp) do
    patch = fn fn_node ->
      if fn_node.node.entry.id == entry_id do
        %{fn_node | node: %{fn_node.node | label: label, label_timestamp: label_timestamp}}
      else
        fn_node
      end
    end

    %{state |
      flat_nodes: Enum.map(state.flat_nodes, patch),
      filtered_nodes: Enum.map(state.filtered_nodes, patch),
      visible_nodes: Enum.map(state.visible_nodes, patch)
    }
  end

  defp handle_fold_or_up(state) do
    case selected_id(state) do
      nil ->
        state

      id ->
        {vis_children, vis_parent} = build_visible_maps(state.visible_nodes)

        if is_foldable(id, vis_children, vis_parent) and not MapSet.member?(state.folded_nodes, id) do
          apply_fold(state, id)
        else
          jump_to_branch_start(state, id, vis_children, vis_parent)
        end
    end
  end

  defp handle_unfold_or_down(state) do
    case selected_id(state) do
      nil ->
        state

      id ->
        if MapSet.member?(state.folded_nodes, id) do
          apply_unfold(state, id)
        else
          {vis_children, vis_parent} = build_visible_maps(state.visible_nodes)
          jump_to_branch_end(state, id, vis_children, vis_parent)
        end
    end
  end

  defp apply_fold(state, id) do
    new_folded = MapSet.put(state.folded_nodes, id)
    new_visible = Tree.fold_filter(state.filtered_nodes, new_folded)
    idx = find_nearest_visible_index(new_visible, state.flat_nodes, id)
    %{state | folded_nodes: new_folded, visible_nodes: new_visible, selected_index: idx}
  end

  defp apply_unfold(state, id) do
    new_folded = MapSet.delete(state.folded_nodes, id)
    new_visible = Tree.fold_filter(state.filtered_nodes, new_folded)
    idx = find_nearest_visible_index(new_visible, state.flat_nodes, id)
    %{state | folded_nodes: new_folded, visible_nodes: new_visible, selected_index: idx}
  end

  defp jump_to_branch_start(state, id, vis_children, vis_parent) do
    target_id = find_segment_start(id, vis_children, vis_parent)
    idx = find_nearest_visible_index(state.visible_nodes, state.flat_nodes, target_id)
    %{state | selected_index: idx}
  end

  defp jump_to_branch_end(state, id, vis_children, vis_parent) do
    target_id = find_segment_end(id, vis_children, vis_parent)
    idx = find_nearest_visible_index(state.visible_nodes, state.flat_nodes, target_id)
    %{state | selected_index: idx}
  end

  defp build_visible_maps(visible_nodes) do
    vis_parent = Map.new(visible_nodes, fn fn_node ->
      {fn_node.node.entry.id, fn_node.node.entry.parent_id}
    end)

    vis_children = Enum.reduce(visible_nodes, %{}, fn fn_node, acc ->
      parent_id = fn_node.node.entry.parent_id
      if parent_id do
        Map.update(acc, parent_id, [fn_node.node.entry.id], &(&1 ++ [fn_node.node.entry.id]))
      else
        acc
      end
    end)

    {vis_children, vis_parent}
  end

  defp is_foldable(id, vis_children, vis_parent) do
    has_children = Map.has_key?(vis_children, id)
    parent_id = Map.get(vis_parent, id)
    parent_sibling_count = if parent_id, do: length(Map.get(vis_children, parent_id, [])), else: 0
    has_children and (is_nil(parent_id) or parent_sibling_count > 1)
  end

  defp find_segment_start(id, vis_children, vis_parent) do
    parent_id = Map.get(vis_parent, id)
    cond do
      is_nil(parent_id) -> id
      length(Map.get(vis_children, parent_id, [])) > 1 -> id
      true -> find_segment_start(parent_id, vis_children, vis_parent)
    end
  end

  defp find_segment_end(id, vis_children, vis_parent) do
    children = Map.get(vis_children, id, [])
    case children do
      [] ->
        id
      [first_child | _] ->
        grandchildren = Map.get(vis_children, first_child, [])
        if length(grandchildren) > 1 do
          hd(Map.get(vis_children, first_child))
        else
          find_segment_end(first_child, vis_children, vis_parent)
        end
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

  defp move_cursor(%__MODULE__{visible_nodes: []} = state, _delta), do: state

  defp move_cursor(%__MODULE__{selected_index: idx, visible_nodes: nodes} = state, delta)
       when delta in [-1, 1] do
    count = length(nodes)
    new_idx = rem(idx + delta + count, count)
    %{state | selected_index: new_idx}
  end

  defp move_cursor(%__MODULE__{selected_index: idx, visible_nodes: nodes} = state, delta) do
    count = length(nodes)
    new_idx = (idx + delta) |> max(0) |> min(count - 1)
    %{state | selected_index: new_idx}
  end

  defp set_filter(%__MODULE__{} = state, new_mode) do
    filtered = Tree.filter(state.flat_nodes, new_mode, state.leaf_id)
    idx = find_nearest_visible_index(filtered, state.flat_nodes, selected_id(state))
    %{state | filter_mode: new_mode, filtered_nodes: filtered, visible_nodes: filtered, folded_nodes: MapSet.new(), selected_index: idx}
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
