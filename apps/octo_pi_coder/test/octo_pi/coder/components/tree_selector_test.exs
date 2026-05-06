defmodule OctoPi.Coder.Components.TreeSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Components.TreeSelector
  alias OctoPi.Coder.Session.Entry

  # ── entry builders ──────────────────────────────────────────────────────

  defp user_entry(id, parent_id, text) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: "2026-04-27T00:00:00Z",
      message: %{"role" => "user", "content" => text}
    }
  end

  defp assistant_entry(id, parent_id, text) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: "2026-04-27T00:00:00Z",
      message: %{
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => text}],
        "stopReason" => "stop",
        "usage" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0, "totalTokens" => 0}
      }
    }
  end

  defp tool_call_only_entry(id, parent_id) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: "2026-04-27T00:00:00Z",
      message: %{
        "role" => "assistant",
        "content" => [%{"type" => "toolCall", "id" => "tc-#{id}", "name" => "read", "arguments" => %{}}],
        "stopReason" => "toolUse",
        "usage" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0, "totalTokens" => 0}
      }
    }
  end

  defp tool_result_entry(id, parent_id) do
    %Entry.Message{
      id: id,
      parent_id: parent_id,
      timestamp: "2026-04-27T00:00:00Z",
      message: %{"role" => "toolResult", "toolCallId" => "tc-#{id}", "toolName" => "read", "content" => "result"}
    }
  end

  defp model_change_entry(id, parent_id) do
    %Entry.ModelChange{
      id: id,
      parent_id: parent_id,
      timestamp: "2026-04-27T00:00:00Z",
      provider: "anthropic",
      model_id: "claude-sonnet-4"
    }
  end

  # ── build_tree/1 ────────────────────────────────────────────────────────

  describe "build_tree/1" do
    test "empty list returns []" do
      assert TreeSelector.build_tree([]) == []
    end

    test "single root with no children" do
      entry = user_entry("u1", nil, "hello")
      [root] = TreeSelector.build_tree([entry])
      assert root.entry.id == "u1"
      assert root.children == []
    end

    test "linear chain: each entry is a child of the previous" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "bye")
      ]

      [root] = TreeSelector.build_tree(entries)
      assert root.entry.id == "u1"
      assert [child1] = root.children
      assert child1.entry.id == "a1"
      assert [child2] = child1.children
      assert child2.entry.id == "u2"
    end

    test "branching: two children of the same parent" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        user_entry("u2a", "a1", "branch A"),
        user_entry("u2b", "a1", "branch B")
      ]

      [root] = TreeSelector.build_tree(entries)
      [child] = root.children
      assert child.entry.id == "a1"
      child_ids = Enum.map(child.children, & &1.entry.id)
      assert "u2a" in child_ids
      assert "u2b" in child_ids
    end

    test "multiple roots" do
      entries = [
        user_entry("u1", nil, "root A"),
        user_entry("u2", nil, "root B")
      ]

      roots = TreeSelector.build_tree(entries)
      assert length(roots) == 2
      root_ids = Enum.map(roots, & &1.entry.id)
      assert "u1" in root_ids
      assert "u2" in root_ids
    end
  end

  # ── flatten/2 ───────────────────────────────────────────────────────────

  describe "flatten/2 — linear chain" do
    setup do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "bye")
      ]

      roots = TreeSelector.build_tree(entries)
      flat = TreeSelector.flatten(roots)
      %{flat: flat}
    end

    test "returns all 3 nodes", %{flat: flat} do
      assert length(flat) == 3
    end

    test "no connectors on a single-child chain", %{flat: flat} do
      refute Enum.any?(flat, & &1.show_connector)
    end

    test "all at indent 0 (single-child chain stays flat)", %{flat: flat} do
      assert Enum.all?(flat, fn n -> n.indent == 0 end)
    end
  end

  describe "flatten/2 — branching tree" do
    # Tree structure:
    # u1
    # a1
    # u2
    # a2       ← branches here
    # ├─ u3a
    #    a3a
    # └─ u3b
    #    a3b
    setup do
      entries = [
        user_entry("u1", nil, "first"),
        assistant_entry("a1", "u1", "resp1"),
        user_entry("u2", "a1", "second"),
        assistant_entry("a2", "u2", "resp2"),
        user_entry("u3a", "a2", "branch A"),
        assistant_entry("a3a", "u3a", "resp3a"),
        user_entry("u3b", "a2", "branch B"),
        assistant_entry("a3b", "u3b", "resp3b")
      ]

      roots = TreeSelector.build_tree(entries)
      flat = TreeSelector.flatten(roots, "a3a")
      %{flat: flat}
    end

    test "branch children show connectors", %{flat: flat} do
      u3a = Enum.find(flat, fn n -> n.node.entry.id == "u3a" end)
      u3b = Enum.find(flat, fn n -> n.node.entry.id == "u3b" end)
      assert u3a.show_connector
      assert u3b.show_connector
    end

    test "active branch (u3a) comes before inactive branch (u3b)", %{flat: flat} do
      ids = Enum.map(flat, fn n -> n.node.entry.id end)
      assert Enum.find_index(ids, &(&1 == "u3a")) < Enum.find_index(ids, &(&1 == "u3b"))
    end

    test "active branch first child is not last, inactive branch is last", %{flat: flat} do
      u3a = Enum.find(flat, fn n -> n.node.entry.id == "u3a" end)
      u3b = Enum.find(flat, fn n -> n.node.entry.id == "u3b" end)
      refute u3a.is_last
      assert u3b.is_last
    end

    test "branch children are at indent 1", %{flat: flat} do
      u3a = Enum.find(flat, fn n -> n.node.entry.id == "u3a" end)
      assert u3a.indent == 1
    end

    test "descendants of a branch point stay at same indent when single-child chain", %{flat: flat} do
      # a3a is a child of u3a (single child), so should be at same indent as u3a
      a3a = Enum.find(flat, fn n -> n.node.entry.id == "a3a" end)
      u3a = Enum.find(flat, fn n -> n.node.entry.id == "u3a" end)
      # First gen after branch: indent + 1 (justBranched rule)
      assert a3a.indent == u3a.indent + 1
    end
  end

  # ── filter/3 ────────────────────────────────────────────────────────────

  describe "filter/3 — :default mode" do
    test "hides model_change entries" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        model_change_entry("mc1", "a1")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :default)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      refute "mc1" in ids
      assert "u1" in ids
      assert "a1" in ids
    end

    test "hides tool-call-only assistants" do
      entries = [
        user_entry("u1", nil, "hello"),
        tool_call_only_entry("tc1", "u1"),
        tool_result_entry("tr1", "tc1")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :default)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      refute "tc1" in ids
    end

    test "keeps tool-call-only assistant when it's the current leaf" do
      entries = [
        user_entry("u1", nil, "hello"),
        tool_call_only_entry("tc1", "u1")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :default, "tc1")
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert "tc1" in ids
    end

    test "keeps tool results" do
      entries = [
        user_entry("u1", nil, "hello"),
        tool_result_entry("tr1", "u1")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :default)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert "tr1" in ids
    end
  end

  describe "filter/3 — :no_tools mode" do
    test "hides tool results in addition to default exclusions" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        tool_result_entry("tr1", "a1")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :no_tools)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      refute "tr1" in ids
      assert "u1" in ids
      assert "a1" in ids
    end
  end

  describe "filter/3 — :user_only mode" do
    test "keeps only user messages" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "bye"),
        model_change_entry("mc1", "u2")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :user_only)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert ids == ["u1", "u2"]
    end
  end

  describe "filter/3 — :labeled_only mode" do
    test "shows only nodes with labels" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        user_entry("u2", "a1", "bye")
      ]

      roots = TreeSelector.build_tree(entries)
      # Add a label to the second root child
      roots_labeled =
        Enum.map(roots, fn root ->
          %{
            root
            | children:
                Enum.map(root.children, fn child ->
                  if child.entry.id == "a1", do: %{child | label: "checkpoint"}, else: child
                end)
          }
        end)

      flat = TreeSelector.flatten(roots_labeled)
      filtered = TreeSelector.filter(flat, :labeled_only)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert ids == ["a1"]
    end

    test "returns empty list when no labels exist" do
      entries = [user_entry("u1", nil, "hello"), assistant_entry("a1", "u1", "hi")]
      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      assert TreeSelector.filter(flat, :labeled_only) == []
    end
  end

  describe "filter/3 — :all mode" do
    test "shows model_change and other settings entries" do
      entries = [
        user_entry("u1", nil, "hello"),
        model_change_entry("mc1", "u1"),
        assistant_entry("a1", "mc1", "hi")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :all)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert "mc1" in ids
    end
  end

  describe "filter/3 — visual recalculation after filtering" do
    test "connector appears at root when intermediate nodes are hidden" do
      # Tree: u1 → a1 → u2a (branch A)
      #            a1 → u2b (branch B)
      # In user-only mode, a1 is hidden. u2a and u2b should appear as children
      # of u1 (the nearest visible ancestor). With 2 visible children under u1,
      # they should get connectors.
      entries = [
        user_entry("u1", nil, "root"),
        assistant_entry("a1", "u1", "assistant"),
        user_entry("u2a", "a1", "branch A"),
        user_entry("u2b", "a1", "branch B")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :user_only)
      ids = Enum.map(filtered, fn n -> n.node.entry.id end)
      assert ids == ["u1", "u2a", "u2b"]

      u2a = Enum.find(filtered, fn n -> n.node.entry.id == "u2a" end)
      u2b = Enum.find(filtered, fn n -> n.node.entry.id == "u2b" end)
      assert u2a.show_connector
      assert u2b.show_connector
      refute u2a.is_last
      assert u2b.is_last
    end
  end

  # ── render_lines/2 — snapshot tests ─────────────────────────────────────

  # The fixture tree mirrors the branching tree from upstream tests:
  #
  # user-1
  # asst-1
  # user-2
  # asst-2          ← branch point
  # ├─ user-3a      ← branch A (active leaf is asst-4a)
  # │  asst-3a
  # │  user-4a
  # │  asst-4a
  # └─ user-3b      ← branch B
  #    asst-3b
  #    user-4b

  defp build_branching_flat(leaf_id \\ "asst-4a") do
    entries = [
      user_entry("user-1", nil, "first message"),
      assistant_entry("asst-1", "user-1", "response 1"),
      user_entry("user-2", "asst-1", "second message"),
      assistant_entry("asst-2", "user-2", "response 2"),
      user_entry("user-3a", "asst-2", "branch A start"),
      assistant_entry("asst-3a", "user-3a", "branch A response"),
      user_entry("user-4a", "asst-3a", "branch A deep"),
      assistant_entry("asst-4a", "user-4a", "branch A leaf"),
      user_entry("user-3b", "asst-2", "branch B start"),
      assistant_entry("asst-3b", "user-3b", "branch B response"),
      user_entry("user-4b", "asst-3b", "branch B deep")
    ]

    entries
    |> TreeSelector.build_tree()
    |> TreeSelector.flatten(leaf_id)
  end

  describe "render_lines/2 — :default mode snapshot" do
    test "linear prefix before branch point has no indentation" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered)

      # First 4 entries are a linear chain — no connectors
      [l1, l2, l3, l4 | _] = lines
      assert l1 =~ "user: first message"
      refute l1 =~ "├─"
      refute l1 =~ "└─"
      assert l2 =~ "assistant: response 1"
      assert l3 =~ "user: second message"
      assert l4 =~ "assistant: response 2"
    end

    test "branch A gets ├─ connector (active branch first)" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered)

      # After the 4 linear entries: branch A with ├─
      branch_a_line = Enum.find(lines, fn l -> l =~ "branch A start" end)
      assert branch_a_line =~ "├─"
    end

    test "branch B gets └─ connector (last sibling)" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered)

      branch_b_line = Enum.find(lines, fn l -> l =~ "branch B start" end)
      assert branch_b_line =~ "└─"
    end

    test "descendants of branch A have │ gutter" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered)

      asst_3a_line = Enum.find(lines, fn l -> l =~ "branch A response" end)
      assert asst_3a_line =~ "│"
    end

    test "descendants of branch B have space gutter (last sibling)" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered)

      # branch B response should NOT have │ (it's the last branch)
      asst_3b_line = Enum.find(lines, fn l -> l =~ "branch B response" end)
      refute asst_3b_line =~ "│"
    end
  end

  describe "render_lines/2 — :user_only mode snapshot" do
    test "only user messages appear in output" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :user_only)
      lines = TreeSelector.render_lines(filtered)

      assert Enum.all?(lines, fn l -> l =~ "user: " end)
    end

    test "user messages from both branches appear" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :user_only)
      lines = TreeSelector.render_lines(filtered)

      assert Enum.any?(lines, fn l -> l =~ "branch A start" end)
      assert Enum.any?(lines, fn l -> l =~ "branch B start" end)
    end
  end

  describe "render_lines/2 — :no_tools mode snapshot" do
    test "tool results are excluded, other messages remain" do
      entries = [
        user_entry("u1", nil, "hello"),
        assistant_entry("a1", "u1", "hi"),
        tool_result_entry("tr1", "a1"),
        user_entry("u2", "tr1", "bye")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :no_tools)
      lines = TreeSelector.render_lines(filtered)

      assert Enum.any?(lines, fn l -> l =~ "user: hello" end)
      assert Enum.any?(lines, fn l -> l =~ "assistant: hi" end)
      refute Enum.any?(lines, fn l -> l =~ "[read]" end)
    end
  end

  describe "render_lines/2 — :all mode snapshot" do
    test "model_change entries appear in output" do
      entries = [
        user_entry("u1", nil, "hello"),
        model_change_entry("mc1", "u1"),
        assistant_entry("a1", "mc1", "hi")
      ]

      flat = entries |> TreeSelector.build_tree() |> TreeSelector.flatten()
      filtered = TreeSelector.filter(flat, :all)
      lines = TreeSelector.render_lines(filtered)

      assert Enum.any?(lines, fn l -> l =~ "model: " end)
    end
  end

  describe "render_lines/2 — active path marker" do
    test "nodes on active path have • marker" do
      flat = build_branching_flat("asst-4a")
      filtered = TreeSelector.filter(flat, :default, "asst-4a")
      lines = TreeSelector.render_lines(filtered, leaf_id: "asst-4a")

      # asst-4a and its ancestors should have • marker
      leaf_line = Enum.find(lines, fn l -> l =~ "branch A leaf" end)
      assert leaf_line =~ "• "
    end

    test "nodes off active path have no • marker" do
      flat = build_branching_flat("asst-4a")
      filtered = TreeSelector.filter(flat, :default, "asst-4a")
      lines = TreeSelector.render_lines(filtered, leaf_id: "asst-4a")

      branch_b_line = Enum.find(lines, fn l -> l =~ "branch B start" end)
      refute branch_b_line =~ "• "
    end
  end

  describe "render_lines/2 — entry content formats" do
    test "toolResult with matching tool call shows formatted tool call" do
      # Assistant message has a toolCall block; toolResult references it by id
      asst = %Entry.Message{
        id: "a1",
        parent_id: nil,
        timestamp: "2026-04-27T00:00:00Z",
        message: %{
          "role" => "assistant",
          "content" => [%{"type" => "toolCall", "id" => "tc-1", "name" => "read", "arguments" => %{"path" => "/home/user/foo.txt"}}],
          "stopReason" => "toolUse",
          "usage" => %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0, "totalTokens" => 0}
        }
      }
      result_entry = %Entry.Message{
        id: "r1",
        parent_id: "a1",
        timestamp: "2026-04-27T00:00:00Z",
        message: %{"role" => "toolResult", "toolCallId" => "tc-1", "toolName" => "read", "content" => "ok"}
      }

      flat =
        [asst, result_entry]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      result_line = Enum.find(lines, &(&1 =~ "read"))
      assert result_line =~ "[read:"
    end

    test "toolResult without matching tool call falls back to tool name" do
      result_entry = %Entry.Message{
        id: "r1",
        parent_id: nil,
        timestamp: "2026-04-27T00:00:00Z",
        message: %{"role" => "toolResult", "toolCallId" => "unknown-id", "toolName" => "bash", "content" => "ok"}
      }

      flat =
        [result_entry]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      assert hd(lines) =~ "[bash]"
    end

    test "compaction shows tokensBefore in Nk format" do
      comp = %Entry.Compaction{
        id: "c1",
        parent_id: nil,
        timestamp: "2026-04-27T00:00:00Z",
        summary: "long summary text",
        first_kept_entry_id: nil,
        tokens_before: 42_500
      }

      flat =
        [comp]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      assert hd(lines) =~ "[compaction: 43k tokens]"
    end

    test "session_info with name shows [title: name]" do
      info = %Entry.SessionInfo{id: "s1", parent_id: nil, timestamp: "t", name: "My Project"}

      flat =
        [info]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      assert hd(lines) =~ "[title: My Project]"
    end

    test "session_info with nil name shows [title: (empty)]" do
      info = %Entry.SessionInfo{id: "s1", parent_id: nil, timestamp: "t", name: nil}

      flat =
        [info]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      assert hd(lines) =~ "[title: (empty)]"
    end

    test "custom_message shows customType prefix and content" do
      msg = %Entry.CustomMessage{
        id: "cm1",
        parent_id: nil,
        timestamp: "t",
        custom_type: "preset",
        content: "some preset text",
        display: "preset",
        details: nil
      }

      flat =
        [msg]
        |> TreeSelector.build_tree()
        |> TreeSelector.flatten()

      lines = TreeSelector.render_lines(flat)
      assert hd(lines) =~ "[preset]:"
      assert hd(lines) =~ "some preset text"
    end
  end

  describe "render_lines/2 — label timestamps" do
    alias OctoPi.Coder.Session.TreeNode
    alias OctoPi.Coder.Components.TreeSelector.FlatNode

    defp flat_node_with_label(label, label_timestamp) do
      entry = %Entry.Message{
        id: "lts-1",
        parent_id: nil,
        timestamp: "2026-04-27T00:00:00Z",
        message: %{"role" => "user", "content" => "hello"}
      }
      node = %TreeNode{entry: entry, children: [], label: label, label_timestamp: label_timestamp}
      %FlatNode{node: node, indent: 0, show_connector: false, is_last: true, gutters: [], is_virtual_root_child: false}
    end

    test "show_label_timestamps: false — no timestamp emitted even when present" do
      flat_node = flat_node_with_label("my-label", "2026-05-06T14:30:00Z")
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: false)
      assert line =~ "[my-label]"
      refute line =~ "14:30"
    end

    test "show_label_timestamps: true, same day — emits HH:MM after label" do
      now = DateTime.utc_now()
      ts = Calendar.strftime(now, "%Y-%m-%dT%H:%M:%SZ")
      flat_node = flat_node_with_label("today-label", ts)
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: true)
      assert line =~ "[today-label]"
      expected_time = Calendar.strftime(now, "%H:%M")
      assert line =~ expected_time
      refute line =~ "/"
    end

    test "show_label_timestamps: true, different day same year — emits M/D HH:MM" do
      flat_node = flat_node_with_label("old-label", "2026-01-15T09:05:00Z")
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: true)
      assert line =~ "[old-label]"
      assert line =~ "1/15 09:05"
    end

    test "show_label_timestamps: true, different year — emits YY/M/D HH:MM" do
      flat_node = flat_node_with_label("ancient-label", "2024-03-07T22:45:00Z")
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: true)
      assert line =~ "[ancient-label]"
      assert line =~ "24/3/7 22:45"
    end

    test "show_label_timestamps: true, no label — no timestamp emitted" do
      flat_node = flat_node_with_label(nil, "2026-05-06T14:30:00Z")
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: true)
      refute line =~ "14:30"
      refute line =~ "["
    end

    test "show_label_timestamps: true, label but no timestamp — label shown without timestamp" do
      flat_node = flat_node_with_label("no-ts-label", nil)
      [line] = TreeSelector.render_lines([flat_node], show_label_timestamps: true)
      assert line =~ "[no-ts-label]"
      refute line =~ "/"
      # no digits after label besides the content
      refute line =~ ~r/\[no-ts-label\] \d/
    end
  end

  describe "render_lines/2 — cursor marker" do
    test "selected node gets › prefix" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered, selected_id: "user-2")

      u2_line = Enum.find(lines, fn l -> l =~ "second message" end)
      assert String.starts_with?(u2_line, "› ")
    end

    test "non-selected nodes get two-space prefix" do
      flat = build_branching_flat()
      filtered = TreeSelector.filter(flat, :default)
      lines = TreeSelector.render_lines(filtered, selected_id: "user-2")

      u1_line = Enum.find(lines, fn l -> l =~ "first message" end)
      assert String.starts_with?(u1_line, "  ")
    end
  end
end
