defmodule OctoPi.Coder.Components.TreeSelector do
  @moduledoc """
  ASCII tree rendering with filter modes. G5a portion of the tree-selector
  component port from
  `tmp/pi-mono/.../modes/interactive/components/tree-selector.ts`.

  This module is purely functional — it takes a tree and produces ASCII
  line strings. TUI interaction (keyboard, cursor, folding) lands in
  G5b/G5c.

  ## Data structures

    * `OctoPi.Coder.Session.TreeNode` — entry with its children (built from
      a flat entry list via `build_tree/1`)
    * `GutterInfo` — ancestor-branch connector state (`│` or space)
    * `FlatNode` — one entry in the flattened walk, carrying computed
      indent / connector / gutter metadata

  ## Filter modes

    * `:default`      — hide settings entries (label, custom,
                        model_change, thinking_level_change,
                        session_info) and tool-call-only assistants
    * `:no_tools`     — default minus tool results
    * `:user_only`    — user messages only
    * `:labeled_only` — only nodes with a label attached
    * `:all`          — show everything (tool-call-only hide still applies)

  After filtering, visual structure (indent/connectors/gutters) is
  recomputed so descendants attach to the nearest visible ancestor —
  matching upstream's `recalculateVisualStructure`.

  ## Entry ID lookup

  Every `OctoPi.Coder.Session.Entry.*` struct has `:id` and `:parent_id`
  fields. `build_tree/1` uses those to reconstruct the tree.

  ## Entry type mapping (upstream → Elixir)

    * `"message"`              → `Entry.Message`
    * `"model_change"`         → `Entry.ModelChange`
    * `"thinking_level_change"`→ `Entry.ThinkingLevelChange`
    * `"label"`                → `Entry.Label`
    * `"custom"`               → `Entry.Custom`
    * `"session_info"`         → `Entry.SessionInfo`
    * `"compaction"`           → `Entry.Compaction`
    * `"branch_summary"`       → `Entry.BranchSummary`
    * `"custom_message"`       → `Entry.CustomMessage`
  """

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.TreeNode

  # ── data structures ──────────────────────────────────────────────────────

  defmodule GutterInfo do
    @moduledoc false
    @enforce_keys [:position, :show]
    defstruct [:position, :show]

    @type t :: %__MODULE__{position: non_neg_integer(), show: boolean()}
  end

  defmodule FlatNode do
    @moduledoc false
    @enforce_keys [:node, :indent, :show_connector, :is_last, :gutters, :is_virtual_root_child]
    defstruct [:node, :indent, :show_connector, :is_last, :gutters, :is_virtual_root_child]

    @type t :: %__MODULE__{
            node: TreeNode.t(),
            indent: non_neg_integer(),
            show_connector: boolean(),
            is_last: boolean(),
            gutters: [OctoPi.Coder.Components.TreeSelector.GutterInfo.t()],
            is_virtual_root_child: boolean()
          }
  end

  @type filter_mode :: :default | :no_tools | :user_only | :labeled_only | :all

  # ── build_tree/1 ─────────────────────────────────────────────────────────

  @doc """
  Build a forest (list of root `TreeNode`s) from a flat list of entries.
  Mirrors the upstream `buildTree` test helper and the session-manager
  internal tree construction.
  """
  @spec build_tree([Entry.t()]) :: [TreeNode.t()]
  def build_tree([]), do: []

  def build_tree(entries) do
    nodes = Enum.map(entries, fn e -> %TreeNode{entry: e, children: []} end)
    by_id = Map.new(nodes, fn n -> {n.entry.id, n} end)

    # Use a mutable-style accumulator: build children lists then assemble.
    {by_id_final, roots_reversed} =
      Enum.reduce(nodes, {by_id, []}, fn node, acc ->
        place_node(node, acc, node.entry.parent_id)
      end)

    roots_reversed
    |> Enum.map(fn root -> Map.fetch!(by_id_final, root.entry.id) end)
    |> Enum.reverse()
    |> Enum.map(&rebuild_children(&1, by_id_final))
  end

  defp place_node(node, {acc_by_id, roots}, nil), do: {acc_by_id, [node | roots]}

  defp place_node(node, {acc_by_id, roots}, parent_id) do
    case Map.get(acc_by_id, parent_id) do
      nil ->
        {acc_by_id, roots}

      parent ->
        updated = %{parent | children: parent.children ++ [node]}
        {Map.put(acc_by_id, parent_id, updated), roots}
    end
  end

  defp rebuild_children(%TreeNode{} = node, by_id) do
    children =
      Enum.map(node.children, fn child ->
        by_id
        |> Map.fetch!(child.entry.id)
        |> rebuild_children(by_id)
      end)

    %{node | children: children}
  end

  # ── flatten/2 ────────────────────────────────────────────────────────────

  @doc """
  Flatten a forest into a DFS-ordered list of `FlatNode`s, computing
  indent / connector / gutter values. `leaf_id` is used to sort
  branches so the active branch appears first.

  Mirrors upstream `flattenTree()`.
  """
  @spec flatten([TreeNode.t()], String.t() | nil) :: [FlatNode.t()]
  def flatten(roots, leaf_id \\ nil) do
    contains_active = build_contains_active_map(roots, leaf_id)
    multiple_roots = length(roots) > 1

    ordered_roots = sort_by_active(roots, contains_active)

    # No Enum.reverse() — Elixir list-as-stack: head is top, so forward
    # order here means the first root is popped first (correct).
    initial_stack =
      ordered_roots
      |> Enum.with_index()
      |> Enum.map(fn {node, i} ->
        is_last = i == length(ordered_roots) - 1
        {node, if(multiple_roots, do: 1, else: 0), multiple_roots, multiple_roots, is_last, [], multiple_roots}
      end)

    do_flatten(initial_stack, [], contains_active, multiple_roots)
  end

  defp do_flatten([], result, _contains_active, _multiple_roots), do: Enum.reverse(result)

  defp do_flatten([item | rest_stack], result, contains_active, multiple_roots) do
    {node, indent, just_branched, show_connector, is_last, gutters, is_virtual_root_child} = item

    flat_node = %FlatNode{
      node: node,
      indent: indent,
      show_connector: show_connector,
      is_last: is_last,
      gutters: gutters,
      is_virtual_root_child: is_virtual_root_child
    }

    children = node.children
    ordered_children = sort_by_active(children, contains_active)
    multiple_children = length(ordered_children) > 1
    child_indent = compute_child_indent(multiple_children, just_branched, indent)
    child_gutters = build_child_gutters(show_connector, is_virtual_root_child, multiple_roots, indent, is_last, gutters)

    child_items =
      ordered_children
      |> Enum.with_index()
      |> Enum.map(fn {child, i} ->
        child_is_last = i == length(ordered_children) - 1
        {child, child_indent, multiple_children, multiple_children, child_is_last, child_gutters, false}
      end)

    do_flatten(child_items ++ rest_stack, [flat_node | result], contains_active, multiple_roots)
  end

  # ── filter/3 ─────────────────────────────────────────────────────────────

  @doc """
  Filter `flat_nodes` by `mode`, then recompute visual structure for the
  filtered set. `leaf_id` marks the current leaf (which is never hidden
  by the tool-call-only check).

  Returns the filtered and visually recalculated `[FlatNode.t()]`.

  Mirrors upstream `applyFilter()` + `recalculateVisualStructure()`.
  """
  @spec filter([FlatNode.t()], filter_mode(), String.t() | nil) :: [FlatNode.t()]
  def filter(flat_nodes, mode \\ :default, leaf_id \\ nil) do
    filtered =
      Enum.filter(flat_nodes, fn flat_node ->
        passes_tool_call_check?(flat_node, leaf_id) and passes_mode_filter?(flat_node, mode)
      end)

    recalculate_visual_structure(filtered, flat_nodes)
  end

  # ── render_lines/2 ───────────────────────────────────────────────────────

  @doc """
  Render `flat_nodes` (already filtered + visual-recalculated) to plain-text
  lines. No ANSI escape codes — suitable for snapshot testing.

  Options:
    * `:leaf_id`       — marks nodes on the active path with `"• "` prefix
    * `:selected_id`   — marks the selected node with `"› "` prefix
      (default `"  "` for all nodes)
    * `:multiple_roots` — if `true`, shift display indent left by 1
      (auto-detected from `flat_nodes` when not provided)
  """
  @spec render_lines([FlatNode.t()], keyword()) :: [String.t()]
  def render_lines(flat_nodes, opts \\ []) do
    leaf_id = Keyword.get(opts, :leaf_id)
    selected_id = Keyword.get(opts, :selected_id)
    multiple_roots = Keyword.get(opts, :multiple_roots, detect_multiple_roots(flat_nodes))

    active_path_ids = build_active_path_ids(flat_nodes, leaf_id)

    Enum.map(flat_nodes, fn flat_node ->
      render_node(flat_node, selected_id, multiple_roots, active_path_ids)
    end)
  end

  # ── private: render helpers ───────────────────────────────────────────────

  # build_active_path_ids returns a MapSet whose internal type Dialyzer
  # cannot resolve to the parametric MapSet.t(String.t()). False positive.
  @dialyzer {:nowarn_function, render_lines: 2, render_node: 4}
  defp render_node(flat_node, selected_id, multiple_roots, active_path_ids) do
    entry = flat_node.node.entry
    cursor = if selected_id && entry.id == selected_id, do: "› ", else: "  "
    display_indent = if multiple_roots, do: max(0, flat_node.indent - 1), else: flat_node.indent
    connector = node_connector(flat_node)
    connector_position = if connector == "", do: -1, else: display_indent - 1
    prefix = build_prefix(display_indent, flat_node.gutters, connector, connector_position, flat_node.is_last)
    path_marker = if MapSet.member?(active_path_ids, entry.id), do: "• ", else: ""
    label = if flat_node.node.label, do: "[#{flat_node.node.label}] ", else: ""
    content = entry_display_text(flat_node.node)
    cursor <> prefix <> path_marker <> label <> content
  end

  defp node_connector(%FlatNode{show_connector: true, is_virtual_root_child: false, is_last: true}), do: "└─ "
  defp node_connector(%FlatNode{show_connector: true, is_virtual_root_child: false}), do: "├─ "
  defp node_connector(_flat_node), do: ""

  defp build_prefix(display_indent, gutters, connector, connector_position, is_last) do
    total_chars = display_indent * 3

    if total_chars == 0 do
      ""
    else
      build_prefix_chars(total_chars, gutters, connector, connector_position, is_last)
    end
  end

  defp build_prefix_chars(total_chars, gutters, connector, connector_position, is_last) do
    Enum.map_join(0..(total_chars - 1)//1, fn i ->
      level = div(i, 3)
      pos = rem(i, 3)
      gutter = Enum.find(gutters, fn g -> g.position == level end)
      prefix_char(gutter, connector, level, connector_position, pos, is_last)
    end)
  end

  defp prefix_char(gutter, _connector, _level, _cp, pos, _last) when not is_nil(gutter) do
    if pos == 0, do: if(gutter.show, do: "│", else: " "), else: " "
  end

  defp prefix_char(_gutter, connector, level, cp, pos, is_last) when connector != "" and level == cp do
    case pos do
      0 -> if is_last, do: "└", else: "├"
      1 -> "─"
      _ -> " "
    end
  end

  defp prefix_char(_gutter, _connector, _level, _cp, _pos, _last), do: " "

  defp entry_display_text(%TreeNode{entry: %Entry.Message{message: %{"role" => "user"} = msg}}) do
    "user: " <> extract_content_text(msg["content"])
  end

  defp entry_display_text(%TreeNode{entry: %Entry.Message{message: %{"role" => "assistant"} = msg}}) do
    text = extract_content_text(msg["content"])
    stop = msg["stopReason"] || msg["stop_reason"]
    assistant_display_text(text, stop)
  end

  defp entry_display_text(%TreeNode{entry: %Entry.Message{message: %{"role" => "toolResult"} = msg}}) do
    tool_name = msg["toolName"] || msg["tool_name"] || "tool"
    "[#{tool_name}]"
  end

  defp entry_display_text(%TreeNode{entry: %Entry.Message{message: %{"role" => "bashExecution"} = msg}}) do
    "[bash]: #{normalize_text(msg["command"] || "")}"
  end

  defp entry_display_text(%TreeNode{entry: %Entry.Message{message: %{"role" => role}}}), do: "[#{role}]"
  defp entry_display_text(%TreeNode{entry: %Entry.ModelChange{model_id: id}}), do: "model: #{id}"
  defp entry_display_text(%TreeNode{entry: %Entry.ThinkingLevelChange{thinking_level: lvl}}), do: "thinking: #{lvl}"

  defp entry_display_text(%TreeNode{entry: %Entry.Compaction{summary: s}}),
    do: "compaction: #{String.slice(s || "", 0, 40)}"

  defp entry_display_text(%TreeNode{entry: %Entry.BranchSummary{summary: s}}),
    do: "branch summary: #{String.slice(s || "", 0, 40)}"

  defp entry_display_text(%TreeNode{entry: %Entry.Label{label: label}}), do: "label: #{label}"
  defp entry_display_text(%TreeNode{entry: %Entry.SessionInfo{}}), do: "session info"
  defp entry_display_text(_node), do: "[entry]"

  defp assistant_display_text("", "aborted"), do: "assistant: (aborted)"
  defp assistant_display_text("", _stop), do: "assistant: (no content)"
  defp assistant_display_text(text, _stop), do: "assistant: " <> text

  defp extract_content_text(nil), do: ""
  defp extract_content_text(s) when is_binary(s), do: normalize_text(s)

  defp extract_content_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => t} when is_binary(t) -> [t]
      %{type: :text, text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join(" ")
    |> normalize_text()
  end

  defp normalize_text(s) when is_binary(s) do
    s |> String.replace(~r/[\n\t]/, " ") |> String.trim()
  end

  # ── private: filter helpers ───────────────────────────────────────────────

  defp passes_tool_call_check?(%FlatNode{node: %TreeNode{entry: entry}}, leaf_id) do
    case entry do
      %Entry.Message{message: %{"role" => "assistant"} = msg}
      when entry.id != leaf_id ->
        has_text = has_text_content?(msg["content"])
        stop = msg["stopReason"] || msg["stop_reason"] || ""
        is_error_or_aborted = stop != "" and stop != "stop" and stop != "toolUse"
        has_text or is_error_or_aborted

      _ ->
        true
    end
  end

  defp passes_mode_filter?(%FlatNode{node: %TreeNode{entry: entry, label: label}}, mode) do
    settings_entry? = settings_entry?(entry)

    case mode do
      :user_only ->
        match?(%Entry.Message{message: %{"role" => "user"}}, entry)

      :no_tools ->
        not settings_entry? and not match?(%Entry.Message{message: %{"role" => "toolResult"}}, entry)

      :labeled_only ->
        label != nil

      :all ->
        true

      :default ->
        not settings_entry?
    end
  end

  defp settings_entry?(%Entry.Label{}), do: true
  defp settings_entry?(%Entry.Custom{}), do: true
  defp settings_entry?(%Entry.ModelChange{}), do: true
  defp settings_entry?(%Entry.ThinkingLevelChange{}), do: true
  defp settings_entry?(%Entry.SessionInfo{}), do: true
  defp settings_entry?(_), do: false

  defp has_text_content?(nil), do: false
  defp has_text_content?(s) when is_binary(s), do: String.trim(s) != ""

  defp has_text_content?(blocks) when is_list(blocks) do
    Enum.any?(blocks, fn
      %{"type" => "text", "text" => t} when is_binary(t) -> String.trim(t) != ""
      _ -> false
    end)
  end

  defp has_text_content?(_), do: false

  # ── private: recalculate_visual_structure ─────────────────────────────────

  defp recalculate_visual_structure([], _full_flat), do: []

  defp recalculate_visual_structure(filtered, full_flat) do
    visible_ids = MapSet.new(filtered, fn fn_node -> fn_node.node.entry.id end)

    entry_map = Map.new(full_flat, fn fn_node -> {fn_node.node.entry.id, fn_node} end)

    find_visible_ancestor = fn node_id ->
      find_visible_ancestor_loop(node_id, entry_map, visible_ids)
    end

    # Build visible parent → children maps
    {_visible_parent, visible_children_map} =
      Enum.reduce(filtered, {%{}, %{nil => []}}, fn fn_node, {vp, vc} ->
        node_id = fn_node.node.entry.id
        ancestor_id = find_visible_ancestor.(node_id)

        vc = Map.update(vc, ancestor_id, [node_id], fn existing -> existing ++ [node_id] end)
        {Map.put(vp, node_id, ancestor_id), vc}
      end)

    visible_root_ids = Map.get(visible_children_map, nil, [])
    multiple_roots = length(visible_root_ids) > 1

    filtered_node_map = Map.new(filtered, fn fn_node -> {fn_node.node.entry.id, fn_node} end)

    # DFS over visible tree to recompute visual properties
    initial_stack =
      visible_root_ids
      |> Enum.with_index()
      |> Enum.map(fn {node_id, i} ->
        is_last = i == length(visible_root_ids) - 1
        {node_id, if(multiple_roots, do: 1, else: 0), multiple_roots, multiple_roots, is_last, [], multiple_roots}
      end)

    updated_map =
      do_recalculate(initial_stack, filtered_node_map, visible_children_map, multiple_roots)

    Enum.map(filtered, fn fn_node -> Map.fetch!(updated_map, fn_node.node.entry.id) end)
  end

  defp do_recalculate([], map, _vc_map, _multiple_roots), do: map

  defp do_recalculate([item | rest], map, vc_map, multiple_roots) do
    {node_id, indent, just_branched, show_connector, is_last, gutters, is_virtual_root_child} = item

    flat_node = Map.fetch!(map, node_id)

    updated = %{
      flat_node
      | indent: indent,
        show_connector: show_connector,
        is_last: is_last,
        gutters: gutters,
        is_virtual_root_child: is_virtual_root_child
    }

    map = Map.put(map, node_id, updated)

    children = Map.get(vc_map, node_id, [])
    multiple_children = length(children) > 1
    child_indent = compute_child_indent(multiple_children, just_branched, indent)
    child_gutters = build_child_gutters(show_connector, is_virtual_root_child, multiple_roots, indent, is_last, gutters)

    child_items =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child_id, i} ->
        child_is_last = i == length(children) - 1
        {child_id, child_indent, multiple_children, multiple_children, child_is_last, child_gutters, false}
      end)

    do_recalculate(child_items ++ rest, map, vc_map, multiple_roots)
  end

  defp find_visible_ancestor_loop(node_id, entry_map, visible_ids) do
    case Map.get(entry_map, node_id) do
      nil ->
        nil

      fn_node ->
        parent_id = fn_node.node.entry.parent_id

        cond do
          parent_id == nil -> nil
          MapSet.member?(visible_ids, parent_id) -> parent_id
          true -> find_visible_ancestor_loop(parent_id, entry_map, visible_ids)
        end
    end
  end

  # ── private: shared helpers ───────────────────────────────────────────────

  defp compute_child_indent(true, _just_branched, indent), do: indent + 1
  defp compute_child_indent(false, just_branched, indent) when just_branched and indent > 0, do: indent + 1
  defp compute_child_indent(false, _just_branched, indent), do: indent

  defp build_child_gutters(show_connector, is_virtual_root_child, multiple_roots, indent, is_last, gutters) do
    connector_displayed = show_connector and not is_virtual_root_child

    if connector_displayed do
      current_display_indent = if multiple_roots, do: max(0, indent - 1), else: indent
      connector_position = max(0, current_display_indent - 1)
      gutters ++ [%GutterInfo{position: connector_position, show: not is_last}]
    else
      gutters
    end
  end

  defp build_contains_active_map(_roots, nil), do: %{}

  defp build_contains_active_map(roots, leaf_id) do
    all_nodes = collect_preorder(roots, [])

    Enum.reduce(Enum.reverse(all_nodes), %{}, fn node, acc ->
      has =
        node.entry.id == leaf_id or
          Enum.any?(node.children, fn child -> Map.get(acc, child.entry.id, false) end)

      Map.put(acc, node.entry.id, has)
    end)
  end

  defp collect_preorder([], acc), do: Enum.reverse(acc)

  defp collect_preorder([node | rest], acc) do
    collect_preorder(node.children ++ rest, [node | acc])
  end

  defp sort_by_active(nodes, contains_active) do
    Enum.sort_by(nodes, fn node ->
      if Map.get(contains_active, node.entry.id, false), do: 0, else: 1
    end)
  end

  defp build_active_path_ids(_flat_nodes, nil), do: MapSet.new()

  defp build_active_path_ids(flat_nodes, leaf_id) do
    entry_map = Map.new(flat_nodes, fn fn_node -> {fn_node.node.entry.id, fn_node} end)

    leaf_id
    |> Stream.unfold(fn
      nil ->
        nil

      id ->
        case Map.get(entry_map, id) do
          nil -> nil
          fn_node -> {id, fn_node.node.entry.parent_id}
        end
    end)
    |> MapSet.new()
  end

  defp detect_multiple_roots(flat_nodes) do
    root_count =
      Enum.count(flat_nodes, fn fn_node -> fn_node.node.entry.parent_id == nil end)

    root_count > 1
  end
end
