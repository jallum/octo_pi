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

  # ── fold_filter/2 ────────────────────────────────────────────────────────

  @doc """
  Remove descendants of folded nodes from `flat_nodes`. Folded nodes
  themselves remain visible. Mirrors upstream fold-filter inside `applyFilter`.
  """
  @spec fold_filter([FlatNode.t()], MapSet.t()) :: [FlatNode.t()]
  def fold_filter(flat_nodes, folded_ids) do
    if MapSet.size(folded_ids) == 0 do
      flat_nodes
    else
      {visible, _hidden} =
        Enum.reduce(flat_nodes, {[], MapSet.new()}, fn fn_node, {acc, hidden} ->
          id = fn_node.node.entry.id
          parent_id = fn_node.node.entry.parent_id

          cond do
            parent_id && MapSet.member?(hidden, parent_id) ->
              {acc, MapSet.put(hidden, id)}

            MapSet.member?(folded_ids, id) ->
              {[fn_node | acc], MapSet.put(hidden, id)}

            true ->
              {[fn_node | acc], hidden}
          end
        end)

      Enum.reverse(visible)
    end
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
    * `:leaf_id`              — marks nodes on the active path with `"• "` prefix
    * `:selected_id`          — marks the selected node with `"› "` prefix
      (default `"  "` for all nodes)
    * `:multiple_roots`       — if `true`, shift display indent left by 1
      (auto-detected from `flat_nodes` when not provided)
    * `:show_label_timestamps` — if `true`, emit label timestamps next to labels
    * `:folded_ids`            — `MapSet` of folded entry IDs for fold markers (⊞/⊟)
  """
  @spec render_lines([FlatNode.t()], keyword()) :: [String.t()]
  def render_lines(flat_nodes, opts \\ []) do
    leaf_id = Keyword.get(opts, :leaf_id)
    selected_id = Keyword.get(opts, :selected_id)
    multiple_roots = Keyword.get(opts, :multiple_roots, detect_multiple_roots(flat_nodes))
    ansi = Keyword.get(opts, :ansi, false)
    show_label_timestamps = Keyword.get(opts, :show_label_timestamps, false)
    folded_ids = Keyword.get(opts, :folded_ids, MapSet.new())
    width = Keyword.get(opts, :width)

    active_path_ids = build_active_path_ids(flat_nodes, leaf_id)
    tool_call_map = build_tool_call_map(flat_nodes)
    fold_marker_map = build_fold_marker_map(flat_nodes, folded_ids)

    Enum.map(flat_nodes, fn flat_node ->
      fold_marker = Map.get(fold_marker_map, flat_node.node.entry.id)

      render_node(
        flat_node,
        selected_id,
        multiple_roots,
        active_path_ids,
        ansi,
        tool_call_map,
        show_label_timestamps,
        fold_marker,
        width
      )
    end)
  end

  # ── private: render helpers ───────────────────────────────────────────────

  # build_active_path_ids returns a MapSet whose internal type Dialyzer
  # cannot resolve to the parametric MapSet.t(String.t()). False positive.
  @dialyzer {:nowarn_function, render_lines: 2, render_node: 9}
  defp render_node(
         flat_node,
         selected_id,
         multiple_roots,
         active_path_ids,
         ansi,
         tool_call_map,
         show_label_timestamps,
         fold_marker,
         width
       ) do
    entry = flat_node.node.entry
    is_selected = selected_id != nil and entry.id == selected_id
    cursor_plain = if is_selected, do: "› ", else: "  "
    cursor = if is_selected, do: ansi_fg("› ", :accent, ansi), else: "  "

    display_indent = if multiple_roots, do: max(0, flat_node.indent - 1), else: flat_node.indent
    connector = node_connector(flat_node)
    connector_position = if connector == "", do: -1, else: display_indent - 1

    prefix =
      build_prefix(display_indent, flat_node.gutters, connector, connector_position, flat_node.is_last, fold_marker)

    root_fold_plain = if not flat_node.show_connector and fold_marker == :folded, do: "⊞ ", else: ""
    root_fold_marker = ansi_fg(root_fold_plain, :accent, ansi)

    path_plain = if MapSet.member?(active_path_ids, entry.id), do: "• ", else: ""
    path_marker = ansi_fg(path_plain, :accent, ansi)

    label_plain = if flat_node.node.label, do: "[#{flat_node.node.label}] ", else: ""
    label_str = ansi_fg(label_plain, :warning, ansi)

    label_ts_plain =
      if show_label_timestamps and not is_nil(flat_node.node.label) and not is_nil(flat_node.node.label_timestamp) do
        format_label_timestamp(flat_node.node.label_timestamp) <> " "
      else
        ""
      end

    label_ts_str = ansi_fg(label_ts_plain, :muted, ansi)

    content_avail =
      if width do
        fixed_vw =
          String.length(cursor_plain) + String.length(prefix) + String.length(root_fold_plain) +
            String.length(path_plain) + String.length(label_plain) + String.length(label_ts_plain)

        max(0, width - fixed_vw)
      end

    content = entry_display_text(flat_node.node, is_selected, ansi, tool_call_map, content_avail)

    line =
      cursor <> ansi_fg(prefix, :dim, ansi) <> root_fold_marker <> path_marker <> label_str <> label_ts_str <> content

    if is_selected and ansi, do: IO.ANSI.reverse() <> line <> IO.ANSI.reset(), else: line
  end

  defp node_connector(%FlatNode{show_connector: true, is_virtual_root_child: false, is_last: true}), do: "└─ "
  defp node_connector(%FlatNode{show_connector: true, is_virtual_root_child: false}), do: "├─ "
  defp node_connector(_flat_node), do: ""

  defp build_prefix(display_indent, gutters, connector, connector_position, is_last, fold_marker) do
    total_chars = display_indent * 3

    if total_chars == 0 do
      ""
    else
      build_prefix_chars(total_chars, gutters, connector, connector_position, is_last, fold_marker)
    end
  end

  defp build_prefix_chars(total_chars, gutters, connector, connector_position, is_last, fold_marker) do
    Enum.map_join(0..(total_chars - 1)//1, fn i ->
      level = div(i, 3)
      pos = rem(i, 3)
      gutter = Enum.find(gutters, fn g -> g.position == level end)
      prefix_char(gutter, connector, level, connector_position, pos, is_last, fold_marker)
    end)
  end

  defp prefix_char(gutter, _connector, _level, _cp, pos, _last, _fm) when not is_nil(gutter) do
    if pos == 0, do: if(gutter.show, do: "│", else: " "), else: " "
  end

  defp prefix_char(_gutter, connector, level, cp, pos, is_last, fold_marker) when connector != "" and level == cp do
    case pos do
      0 -> if is_last, do: "└", else: "├"
      1 -> fold_connector_char(fold_marker)
      _ -> " "
    end
  end

  defp prefix_char(_gutter, _connector, _level, _cp, _pos, _last, _fm), do: " "

  defp fold_connector_char(:folded), do: "⊞"
  defp fold_connector_char(:foldable), do: "⊟"
  defp fold_connector_char(_), do: "─"

  defp build_fold_marker_map(flat_nodes, folded_ids) do
    visible_children =
      Enum.reduce(flat_nodes, %{}, fn fn_node, acc ->
        parent_id = fn_node.node.entry.parent_id

        if parent_id do
          Map.update(acc, parent_id, [fn_node.node.entry.id], &[fn_node.node.entry.id | &1])
        else
          acc
        end
      end)

    Map.new(flat_nodes, fn fn_node ->
      id = fn_node.node.entry.id
      parent_id = fn_node.node.entry.parent_id
      has_children = Map.has_key?(visible_children, id)
      parent_sibling_count = if parent_id, do: length(Map.get(visible_children, parent_id, [])), else: 0

      marker =
        cond do
          MapSet.member?(folded_ids, id) -> :folded
          has_children and (is_nil(parent_id) or parent_sibling_count > 1) -> :foldable
          true -> nil
        end

      {id, marker}
    end)
  end

  defp entry_display_text(node, is_selected, ansi, tool_call_map, content_avail) do
    result = entry_content(node, ansi, tool_call_map, content_avail)
    if is_selected and ansi, do: IO.ANSI.bright() <> result <> IO.ANSI.reset(), else: result
  end

  defp entry_content(%TreeNode{entry: %Entry.Message{message: %{"role" => "user"} = msg}}, ansi, _tcm, content_avail) do
    role = "user: "
    text = msg["content"] |> extract_content_text() |> truncate_content(avail(content_avail, String.length(role)))
    ansi_fg(role, :accent, ansi) <> text
  end

  defp entry_content(
         %TreeNode{entry: %Entry.Message{message: %{"role" => "assistant"} = msg}},
         ansi,
         _tcm,
         content_avail
       ) do
    text = extract_content_text(msg["content"])
    stop = msg["stopReason"] || msg["stop_reason"]
    assistant_content(text, stop, ansi, content_avail)
  end

  defp entry_content(
         %TreeNode{entry: %Entry.Message{message: %{"role" => "toolResult"} = msg}},
         ansi,
         tcm,
         content_avail
       ) do
    tool_call_id = msg["toolCallId"] || msg["tool_call_id"]

    text =
      case tool_call_id && Map.get(tcm, tool_call_id) do
        %{name: name, arguments: args} -> format_tool_call(name, args)
        _ -> "[#{msg["toolName"] || msg["tool_name"] || "tool"}]"
      end

    ansi_fg(truncate_content(text, content_avail), :muted, ansi)
  end

  defp entry_content(
         %TreeNode{entry: %Entry.Message{message: %{"role" => "bashExecution"} = msg}},
         ansi,
         _tcm,
         content_avail
       ) do
    text = truncate_content("[bash]: #{normalize_text(msg["command"] || "")}", content_avail)
    ansi_fg(text, :dim, ansi)
  end

  defp entry_content(%TreeNode{entry: %Entry.Message{message: %{"role" => role}}}, ansi, _tcm, _content_avail),
    do: ansi_fg("[#{role}]", :dim, ansi)

  defp entry_content(%TreeNode{entry: %Entry.ModelChange{model_id: id}}, ansi, _tcm, _content_avail),
    do: ansi_fg("[model: #{id}]", :dim, ansi)

  defp entry_content(%TreeNode{entry: %Entry.ThinkingLevelChange{thinking_level: lvl}}, ansi, _tcm, _content_avail),
    do: ansi_fg("[thinking: #{lvl}]", :dim, ansi)

  defp entry_content(%TreeNode{entry: %Entry.Compaction{tokens_before: tokens}}, ansi, _tcm, _content_avail) do
    k = if is_integer(tokens), do: round(tokens / 1000), else: 0
    ansi_fg("[compaction: #{k}k tokens]", :border_accent, ansi)
  end

  defp entry_content(%TreeNode{entry: %Entry.BranchSummary{summary: s}}, ansi, _tcm, content_avail) do
    role = "[branch summary]: "

    text =
      (s || "")
      |> String.slice(0, 40)
      |> normalize_text()
      |> truncate_content(avail(content_avail, String.length(role)))

    ansi_fg(role, :warning, ansi) <> text
  end

  defp entry_content(%TreeNode{entry: %Entry.Label{label: label}}, ansi, _tcm, _content_avail),
    do: ansi_fg("label: #{label}", :dim, ansi)

  defp entry_content(%TreeNode{entry: %Entry.SessionInfo{name: name}}, ansi, _tcm, _content_avail) when is_binary(name),
    do: ansi_fg("[title: #{name}]", :dim, ansi)

  defp entry_content(%TreeNode{entry: %Entry.SessionInfo{}}, ansi, _tcm, _content_avail),
    do: ansi_fg("[title: (empty)]", :dim, ansi)

  defp entry_content(
         %TreeNode{entry: %Entry.CustomMessage{custom_type: type, content: content}},
         ansi,
         _tcm,
         content_avail
       ) do
    role = "[#{type}]: "

    raw =
      case content do
        s when is_binary(s) ->
          s

        blocks when is_list(blocks) ->
          blocks
          |> Enum.flat_map(fn
            %{"type" => "text", "text" => t} when is_binary(t) -> [t]
            _ -> []
          end)
          |> Enum.join("")

        _ ->
          ""
      end

    text = raw |> normalize_text() |> truncate_content(avail(content_avail, String.length(role)))
    ansi_fg(role, :custom_label, ansi) <> text
  end

  defp entry_content(_node, _ansi, _tcm, _content_avail), do: "[entry]"

  defp assistant_content("", "aborted", ansi, _content_avail),
    do: ansi_fg("assistant: ", :success, ansi) <> ansi_fg("(aborted)", :muted, ansi)

  defp assistant_content("", _stop, ansi, _content_avail),
    do: ansi_fg("assistant: ", :success, ansi) <> ansi_fg("(no content)", :muted, ansi)

  defp assistant_content(text, _stop, ansi, content_avail) do
    role = "assistant: "
    truncated = truncate_content(text, avail(content_avail, String.length(role)))
    ansi_fg(role, :success, ansi) <> truncated
  end

  defp avail(nil, _role_len), do: nil
  defp avail(content_avail, role_len), do: max(0, content_avail - role_len)

  defp truncate_content(text, nil), do: text
  defp truncate_content(_text, max_width) when max_width <= 0, do: ""

  defp truncate_content(text, max_width) do
    text = text |> String.replace(~r/\s+/, " ") |> String.trim()

    if display_width(text) <= max_width do
      text
    else
      # Walk grapheme-by-grapheme keeping display-column budget (leave 1 col for "…")
      graphemes = String.graphemes(text)

      {kept, _} =
        Enum.reduce_while(graphemes, {[], 0}, fn g, {acc, w} ->
          gw = grapheme_display_width(g)
          if w + gw <= max_width - 1, do: {:cont, {[g | acc], w + gw}}, else: {:halt, {acc, w}}
        end)

      kept |> Enum.reverse() |> Enum.join() |> Kernel.<>("…")
    end
  end

  # Display column width of a single grapheme cluster using East Asian Width heuristic.
  # Covers Hangul, CJK, fullwidth forms, and emoji (supplementary plane).
  # Symbols/punctuation in U+1100–U+2E7F (bullets, box-drawing, etc.) are narrow (1).
  defp grapheme_display_width(<<cp::utf8, _::binary>>) do
    cond do
      cp < 0x1100 -> 1
      # Hangul Jamo
      cp <= 0x115F -> 2
      # Misc punctuation, symbols (narrow)
      cp < 0x2E80 -> 1
      # CJK Radicals, CJK Unified Ideographs
      cp <= 0x9FFF -> 2
      cp < 0xAC00 -> 1
      # Hangul Syllables
      cp <= 0xD7FF -> 2
      cp < 0xF900 -> 1
      # CJK Compatibility
      cp <= 0xFAFF -> 2
      cp < 0xFF01 -> 1
      # Fullwidth Latin/Katakana
      cp <= 0xFF60 -> 2
      cp < 0x10000 -> 1
      # Supplementary: emoji, etc.
      true -> 2
    end
  end

  defp grapheme_display_width(_), do: 1

  defp display_width(text) do
    text |> String.graphemes() |> Enum.reduce(0, &(grapheme_display_width(&1) + &2))
  end

  defp ansi_fg(text, _role, false), do: text
  defp ansi_fg("", _role, _ansi), do: ""
  defp ansi_fg(text, :accent, true), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :dim, true), do: IO.ANSI.faint() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :success, true), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :warning, true), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :muted, true), do: IO.ANSI.faint() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :border_accent, true), do: IO.ANSI.cyan() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, :custom_label, true), do: IO.ANSI.magenta() <> text <> IO.ANSI.reset()
  defp ansi_fg(text, _role, true), do: text

  defp format_label_timestamp(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} ->
        now = DateTime.utc_now()
        same_day = dt.year == now.year and dt.month == now.month and dt.day == now.day
        same_year = dt.year == now.year

        if same_day do
          "~2..0B:~2..0B" |> :io_lib.format([dt.hour, dt.minute]) |> IO.iodata_to_binary()
        else
          h = "~2..0B:~2..0B" |> :io_lib.format([dt.hour, dt.minute]) |> IO.iodata_to_binary()

          if same_year do
            "#{dt.month}/#{dt.day} #{h}"
          else
            yy = rem(dt.year, 100)
            "#{yy}/#{dt.month}/#{dt.day} #{h}"
          end
        end

      _ ->
        ""
    end
  end

  defp format_label_timestamp(_), do: ""

  defp build_tool_call_map(flat_nodes) do
    Enum.reduce(flat_nodes, %{}, fn %FlatNode{node: %TreeNode{entry: entry}}, acc ->
      case entry do
        %Entry.Message{message: %{"role" => "assistant", "content" => content}} when is_list(content) ->
          Enum.reduce(content, acc, fn
            %{"type" => "toolCall", "id" => id, "name" => name, "arguments" => args}, a ->
              Map.put(a, id, %{name: name, arguments: args || %{}})

            _, a ->
              a
          end)

        _ ->
          acc
      end
    end)
  end

  defp format_tool_call(name, args) do
    home = System.get_env("HOME") || ""

    shorten = fn p ->
      s = to_string(p)
      if home != "" and String.starts_with?(s, home), do: "~" <> String.slice(s, String.length(home)..-1//1), else: s
    end

    case name do
      "read" ->
        path = shorten.(args["path"] || args["file_path"] || "")
        offset = args["offset"]
        limit = args["limit"]

        display =
          if offset || limit do
            start = offset || 1
            finish = if limit, do: "-#{start + limit - 1}", else: ""
            "#{path}:#{start}#{finish}"
          else
            path
          end

        "[read: #{display}]"

      "write" ->
        "[write: #{shorten.(args["path"] || args["file_path"] || "")}]"

      "edit" ->
        "[edit: #{shorten.(args["path"] || args["file_path"] || "")}]"

      "bash" ->
        raw = to_string(args["command"] || "")
        cmd = raw |> String.replace(~r/[\n\t]/, " ") |> String.trim() |> String.slice(0, 50)
        "[bash: #{cmd}#{if String.length(raw) > 50, do: "...", else: ""}]"

      "grep" ->
        "[grep: /#{args["pattern"] || ""}/ in #{shorten.(args["path"] || ".")}]"

      "find" ->
        "[find: #{args["pattern"] || ""} in #{shorten.(args["path"] || ".")}]"

      "ls" ->
        "[ls: #{shorten.(args["path"] || ".")}]"

      _ ->
        args_str = Jason.encode!(args)
        "[#{name}: #{String.slice(args_str, 0, 40)}#{if String.length(args_str) > 40, do: "...", else: ""}]"
    end
  end

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
