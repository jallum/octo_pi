defmodule OctoPi.TUI.Components.TreeSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.TUI.Components.TreeSelector
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp user_entry(id, parent_id, text) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: nil,
      message: %{"role" => "user", "content" => text}
    }
  end

  defp asst_entry(id, parent_id, text) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: nil,
      message: %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "stopReason" => "stop"
      }
    }
  end

  defp model_change(id, parent_id) do
    %Entry.ModelChange{
      id: id,
      parent_id: parent_id,
      timestamp: nil,
      provider: "anthropic",
      model_id: "claude-sonnet-4"
    }
  end

  defp press_named(state, name) when is_atom(name) do
    TreeSelector.handle_key(state, %Key{key: name, modifiers: []})
  end

  defp press_ctrl(state, char) do
    TreeSelector.handle_key(state, %Key{key: char, modifiers: [:ctrl]})
  end

  # ── new/2 — construction ──────────────────────────────────────────────────

  describe "new/2" do
    test "builds from flat entries" do
      entries = [user_entry("u1", nil, "hi"), asst_entry("a1", "u1", "hello")]
      sel = TreeSelector.new(entries)
      assert TreeSelector.selected_id(sel)
    end

    test "initial filter defaults to :default" do
      sel = TreeSelector.new([user_entry("u1", nil, "hi")])
      assert sel.filter_mode == :default
    end

    test "pre-selects initial_selected_id when provided" do
      entries = [
        user_entry("u1", nil, "hi"),
        asst_entry("a1", "u1", "hello"),
        user_entry("u2", "a1", "bye")
      ]

      sel = TreeSelector.new(entries, initial_selected_id: "a1")
      assert TreeSelector.selected_id(sel) == "a1"
    end

    test "falls back to leaf_id when no initial_selected_id" do
      entries = [
        user_entry("u1", nil, "hi"),
        asst_entry("a1", "u1", "hello")
      ]

      sel = TreeSelector.new(entries, leaf_id: "a1")
      assert TreeSelector.selected_id(sel) == "a1"
    end

    test "metadata-only leaf → selects nearest visible ancestor" do
      entries = [
        user_entry("u1", nil, "hello"),
        asst_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "active branch"),
        model_change("m1", "u2"),
        user_entry("u3", "a1", "sibling")
      ]

      sel = TreeSelector.new(entries, leaf_id: "m1")
      # model_change is filtered out in :default → should land on u2
      assert TreeSelector.selected_id(sel) == "u2"
    end
  end

  # ── cursor movement ───────────────────────────────────────────────────────

  describe "cursor movement" do
    setup do
      entries = [
        user_entry("u1", nil, "1"),
        asst_entry("a1", "u1", "2"),
        user_entry("u2", "a1", "3")
      ]

      {:ok, sel: TreeSelector.new(entries, leaf_id: "u2")}
    end

    test "down moves cursor forward", %{sel: sel} do
      sel0 = %{sel | selected_index: 0}
      {sel1, []} = press_named(sel0, :down)
      assert sel1.selected_index == 1
    end

    test "up moves cursor backward", %{sel: sel} do
      sel2 = %{sel | selected_index: 2}
      {sel1, []} = press_named(sel2, :up)
      assert sel1.selected_index == 1
    end

    test "up at first entry wraps to last", %{sel: sel} do
      sel0 = %{sel | selected_index: 0}
      {sel1, []} = press_named(sel0, :up)
      assert sel1.selected_index == length(sel.filtered_nodes) - 1
    end

    test "down at last entry wraps to first", %{sel: sel} do
      last = length(sel.filtered_nodes) - 1
      sel_last = %{sel | selected_index: last}
      {sel0, []} = press_named(sel_last, :down)
      assert sel0.selected_index == 0
    end

    test "page_down advances by max_visible_lines", %{sel: sel} do
      sel0 = %{sel | selected_index: 0, max_visible_lines: 2}
      {sel1, []} = press_named(sel0, :page_down)
      expected = min(2, length(sel.filtered_nodes) - 1)
      assert sel1.selected_index == expected
    end

    test "page_up retreats by max_visible_lines", %{sel: sel} do
      last = length(sel.filtered_nodes) - 1
      sel_last = %{sel | selected_index: last, max_visible_lines: 2}
      {sel1, []} = press_named(sel_last, :page_up)
      assert sel1.selected_index == max(0, last - 2)
    end
  end

  # ── selection commit ──────────────────────────────────────────────────────

  describe "selection commit" do
    test "enter emits {:select, id}" do
      entries = [user_entry("u1", nil, "hi")]
      sel = TreeSelector.new(entries)
      {_sel1, events} = press_named(sel, :enter)
      assert events == [{:select, "u1"}]
    end

    test "enter on empty list emits nothing" do
      sel = %TreeSelector{
        entries: [],
        keybindings: Keybindings.new(),
        flat_nodes: [],
        filtered_nodes: []
      }

      {_sel1, events} = press_named(sel, :enter)
      assert events == []
    end
  end

  # ── cancellation ──────────────────────────────────────────────────────────

  describe "cancellation" do
    test "escape emits :cancel" do
      entries = [user_entry("u1", nil, "hi")]
      sel = TreeSelector.new(entries)
      {_sel1, events} = press_named(sel, :escape)
      assert events == [:cancel]
    end
  end

  # ── filter cycling ────────────────────────────────────────────────────────

  describe "filter cycling" do
    setup do
      entries = [
        user_entry("u1", nil, "hello"),
        asst_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "bye")
      ]

      {:ok, sel: TreeSelector.new(entries, leaf_id: "u2")}
    end

    test "cycleForward advances through filter modes", %{sel: sel} do
      {sel1, []} = press_ctrl(sel, ?o)
      assert sel1.filter_mode == :no_tools
      {sel2, []} = press_ctrl(sel1, ?o)
      assert sel2.filter_mode == :user_only
      {sel3, []} = press_ctrl(sel2, ?o)
      assert sel3.filter_mode == :labeled_only
      {sel4, []} = press_ctrl(sel3, ?o)
      assert sel4.filter_mode == :all
      {sel5, []} = press_ctrl(sel4, ?o)
      assert sel5.filter_mode == :default
    end

    test "ctrl+d sets filter to :default", %{sel: sel} do
      sel_no_tools = %{sel | filter_mode: :no_tools}
      {sel1, []} = press_ctrl(sel_no_tools, ?d)
      assert sel1.filter_mode == :default
    end

    test "ctrl+u toggles :user_only ↔ :default", %{sel: sel} do
      {sel1, []} = press_ctrl(sel, ?u)
      assert sel1.filter_mode == :user_only
      {sel2, []} = press_ctrl(sel1, ?u)
      assert sel2.filter_mode == :default
    end

    test "filter change preserves nearest visible ancestor (parent traversal)", %{sel: _sel} do
      entries = [
        user_entry("u1", nil, "hello"),
        asst_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "active"),
        asst_entry("a2", "u2", "response"),
        user_entry("u3", "a1", "sibling")
      ]

      sel = TreeSelector.new(entries, leaf_id: "a2", initial_selected_id: "a2")
      assert TreeSelector.selected_id(sel) == "a2"

      # Switch to user-only: a2 (assistant) is hidden → should land on u2 (parent)
      {sel1, []} = press_ctrl(sel, ?u)
      assert sel1.filter_mode == :user_only
      assert TreeSelector.selected_id(sel1) == "u2"
    end

    test "filter change recomputes filtered_nodes", %{sel: sel} do
      default_count = length(sel.filtered_nodes)
      {sel1, []} = press_ctrl(sel, ?u)
      user_count = length(sel1.filtered_nodes)
      assert user_count < default_count
    end
  end

  # ── render/2 ─────────────────────────────────────────────────────────────

  describe "render/2" do
    test "returns one line per filtered node plus header, hints, search, and count" do
      entries = [
        user_entry("u1", nil, "hello"),
        asst_entry("a1", "u1", "world")
      ]

      sel = TreeSelector.new(entries, leaf_id: "a1")
      lines = TreeSelector.render(sel, 80)
      assert length(lines) == length(sel.filtered_nodes) + 5
    end

    test "selected entry shows › cursor" do
      entries = [user_entry("u1", nil, "hi"), asst_entry("a1", "u1", "ho")]
      sel = TreeSelector.new(entries, initial_selected_id: "u1")
      lines = TreeSelector.render(sel, 80)
      # Fourth line is first data entry (0=header, 1=hints, 2=search, 3=first entry)
      assert Enum.at(lines, 3) =~ "›"
    end

    test "non-selected entries show space cursor" do
      entries = [user_entry("u1", nil, "hi"), asst_entry("a1", "u1", "ho")]
      sel = TreeSelector.new(entries, initial_selected_id: "u1")
      lines = TreeSelector.render(sel, 80)
      # Fifth line is second data entry
      refute Enum.at(lines, 4) =~ "›"
    end

    test "first line is Session Tree header with dashed borders" do
      entries = [user_entry("u1", nil, "hello")]
      sel = TreeSelector.new(entries)
      lines = TreeSelector.render(sel, 80)
      header = hd(lines)
      assert header =~ "Session Tree"
      assert String.starts_with?(header, "─── ")
      assert String.length(header) == 80
    end

    test "second-to-last line is a dashed separator" do
      entries = [user_entry("u1", nil, "hello")]
      sel = TreeSelector.new(entries)
      lines = TreeSelector.render(sel, 80)
      sep = Enum.at(lines, length(lines) - 2)
      assert sep == String.duplicate("─", 80)
    end

    test "second line is navigation hints" do
      entries = [user_entry("u1", nil, "hello")]
      sel = TreeSelector.new(entries)
      lines = TreeSelector.render(sel, 80)
      # Second line should contain navigation hints
      assert Enum.at(lines, 1) =~ "↑/↓"
    end

    test "third line is search prompt" do
      entries = [user_entry("u1", nil, "hello")]
      sel = TreeSelector.new(entries)
      lines = TreeSelector.render(sel, 80)
      # Third line should be "Type to search:"
      assert Enum.at(lines, 2) =~ "Type to search"
    end

    test "last line is count badge showing visible/total" do
      entries = [
        user_entry("u1", nil, "hello"),
        asst_entry("a1", "u1", "world")
      ]

      sel = TreeSelector.new(entries)
      lines = TreeSelector.render(sel, 80)
      # Last line should contain "(2/2)" count badge
      last_line = List.last(lines)
      assert last_line =~ "(2/2)"
    end

    test "windowed: only max_visible_lines entries are rendered" do
      # Build 10 entries in a chain, limit to 5 visible
      entries =
        1..10
        |> Enum.reduce([], fn i, acc ->
          parent = if i == 1, do: nil, else: "u#{i - 1}"
          [user_entry("u#{i}", parent, "message #{i}") | acc]
        end)
        |> Enum.reverse()

      # Select entry 5, max_visible_lines 3 → window centers around 5
      sel = TreeSelector.new(entries, initial_selected_id: "u5", max_visible_lines: 3)
      lines = TreeSelector.render(sel, 80)

      # 3 data lines + 5 chrome lines (header, hints, search, bottom border, count)
      assert length(lines) == 3 + 5
    end

    test "windowed: selected entry is always visible" do
      entries =
        1..10
        |> Enum.reduce([], fn i, acc ->
          parent = if i == 1, do: nil, else: "u#{i - 1}"
          [user_entry("u#{i}", parent, "message #{i}") | acc]
        end)
        |> Enum.reverse()

      sel = TreeSelector.new(entries, initial_selected_id: "u8", max_visible_lines: 3)
      lines = TreeSelector.render(sel, 80)

      # The selected entry content (or cursor) must appear in the data lines
      data_lines = Enum.slice(lines, 3, 3)
      assert Enum.any?(data_lines, &(&1 =~ "›"))
    end
  end

  # ── node folding ──────────────────────────────────────────────────────────

  describe "node folding" do
    defp press_ctrl_named(state, name) do
      TreeSelector.handle_key(state, %Key{key: name, modifiers: [:ctrl]})
    end

    # u1 → a1 → [u2a → a2a (branch A), u2b (branch B)]
    # u2a is foldable: has child a2a, parent a1 has 2 children
    defp branching_with_children do
      entries = [
        user_entry("u1", nil, "root"),
        asst_entry("a1", "u1", "level 1"),
        user_entry("u2a", "a1", "branch A"),
        asst_entry("a2a", "u2a", "response A"),
        user_entry("u2b", "a1", "branch B")
      ]

      TreeSelector.new(entries, initial_selected_id: "u2a")
    end

    test "ctrl+left on foldable node adds it to folded_nodes" do
      sel = branching_with_children()
      {sel1, []} = press_ctrl_named(sel, :left)
      assert MapSet.member?(sel1.folded_nodes, "u2a")
    end

    test "ctrl+right on folded node removes it from folded_nodes" do
      sel = branching_with_children()
      {sel1, []} = press_ctrl_named(sel, :left)
      assert MapSet.member?(sel1.folded_nodes, "u2a")
      {sel2, []} = press_ctrl_named(sel1, :right)
      refute MapSet.member?(sel2.folded_nodes, "u2a")
    end

    test "filter change clears folded_nodes" do
      sel = branching_with_children()
      {sel1, []} = press_ctrl_named(sel, :left)
      assert MapSet.size(sel1.folded_nodes) > 0
      {sel2, []} = press_ctrl(sel1, ?u)
      assert MapSet.size(sel2.folded_nodes) == 0
    end

    test "ctrl+left on non-foldable node jumps to branch segment start (parent is branch head)" do
      entries = [
        user_entry("u1", nil, "root"),
        asst_entry("a1", "u1", "mid"),
        user_entry("u2a", "a1", "branch A"),
        asst_entry("a2a", "u2a", "response A"),
        user_entry("u2b", "a1", "branch B")
      ]

      # a2a is not foldable (has no children), but its parent u2a is a branch start
      sel = TreeSelector.new(entries, initial_selected_id: "a2a")
      {sel1, []} = press_ctrl_named(sel, :left)
      # Should jump to u2a (start of segment: its parent a1 has 2 children)
      assert TreeSelector.selected_id(sel1) == "u2a"
    end

    test "ctrl+right on non-folded node follows first-child path to end of branch chain" do
      sel = branching_with_children()
      # cursor on a1 (branch point with children u2a, u2b)
      a1_idx = Enum.find_index(sel.visible_nodes, &(&1.node.entry.id == "a1"))
      sel_at_a1 = %{sel | selected_index: a1_idx}
      {sel1, []} = press_ctrl_named(sel_at_a1, :right)
      # follows first child chain: a1 → u2a → a2a (leaf)
      assert TreeSelector.selected_id(sel1) == "a2a"
    end

    test "visible_nodes excludes descendants of folded nodes" do
      sel = branching_with_children()
      {sel1, []} = press_ctrl_named(sel, :left)
      visible_ids = Enum.map(sel1.visible_nodes, & &1.node.entry.id)
      assert "u2a" in visible_ids
      refute "a2a" in visible_ids
      assert "u2b" in visible_ids
    end
  end

  # ── label editing ─────────────────────────────────────────────────────────

  describe "label editing" do
    setup do
      entries = [user_entry("u1", nil, "hi"), asst_entry("a1", "u1", "hello")]
      {:ok, sel: TreeSelector.new(entries, initial_selected_id: "u1")}
    end

    defp press_shift(state, char) do
      TreeSelector.handle_key(state, %Key{key: char, modifiers: [:shift]})
    end

    test "shift+L opens label input mode", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      assert sel1.label_input
    end

    test "label input is pre-filled with existing label", %{sel: sel} do
      # Give u1 a label first by patching flat_nodes
      labeled_sel =
        put_in(
          sel.flat_nodes,
          Enum.map(sel.flat_nodes, fn fn_node ->
            if fn_node.node.entry.id == "u1",
              do: %{fn_node | node: %{fn_node.node | label: "my-label"}},
              else: fn_node
          end)
        )

      labeled_sel = %{
        labeled_sel
        | filtered_nodes:
            Enum.map(labeled_sel.filtered_nodes, fn fn_node ->
              if fn_node.node.entry.id == "u1",
                do: %{fn_node | node: %{fn_node.node | label: "my-label"}},
                else: fn_node
            end)
      }

      {sel1, []} = press_shift(labeled_sel, ?l)
      {_entry_id, input} = sel1.label_input
      assert input.value == "my-label"
    end

    test "render in label input mode shows label prompt and input", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      lines = TreeSelector.render(sel1, 80)
      assert Enum.any?(lines, &(&1 =~ "Label"))
      assert Enum.any?(lines, &(&1 =~ "enter"))
    end

    test "escape in label input mode cancels and returns to tree", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      {sel2, events} = press_named(sel1, :escape)
      assert sel2.label_input == nil
      assert events == []
    end

    test "enter in label input mode emits {:label_change, id, label}", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      {_entry_id, input} = sel1.label_input
      sel_typed = %{sel1 | label_input: {"u1", %{input | value: "new-label", cursor: 9}}}
      {sel2, events} = press_named(sel_typed, :enter)
      assert sel2.label_input == nil
      assert [{:label_change, "u1", "new-label"}] = events
    end

    test "enter with empty input emits {:label_change, id, nil}", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      {sel2, events} = press_named(sel1, :enter)
      assert [{:label_change, "u1", nil}] = events
      assert sel2.label_input == nil
    end

    test "label change updates flat_nodes in memory", %{sel: sel} do
      {sel1, []} = press_shift(sel, ?l)
      {_entry_id, input} = sel1.label_input
      sel_typed = %{sel1 | label_input: {"u1", %{input | value: "mem-label", cursor: 9}}}
      {sel2, _events} = press_named(sel_typed, :enter)
      fn_node = Enum.find(sel2.flat_nodes, &(&1.node.entry.id == "u1"))
      assert fn_node.node.label == "mem-label"
    end

    test "shift+L on empty tree does nothing", %{sel: _sel} do
      empty = %TreeSelector{keybindings: Keybindings.new(), flat_nodes: [], filtered_nodes: []}
      {empty2, events} = press_shift(empty, ?l)
      assert events == []
      assert empty2.label_input == nil
    end
  end
end
