defmodule OctoPi.Coder.SessionManagerTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionManager

  @fixture_root Path.expand("../../fixtures", __DIR__)

  describe "load/1 — error paths" do
    test "missing file returns :enoent" do
      assert {:error, :enoent} =
               SessionManager.load(Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}.jsonl"))
    end

    test "empty file returns :empty" do
      tmp = scratch("empty.jsonl")
      File.write!(tmp, "")
      assert {:error, :empty} = SessionManager.load(tmp)
    end

    test "first line not a header returns :missing_header" do
      tmp = scratch("noheader.jsonl")
      File.write!(tmp, ~s({"type":"message","id":"a","parentId":null,"timestamp":"t","message":{}}\n))
      assert {:error, :missing_header} = SessionManager.load(tmp)
    end
  end

  describe "load/1 — v3 round-trip" do
    test "loads a v3 session and preserves entry chain" do
      tmp = scratch("v3.jsonl")

      File.write!(tmp, """
      {"type":"session","version":3,"id":"sess-1","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t","message":{"role":"assistant","content":"hey"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert sm.session_id == "sess-1"
      assert sm.cwd == "/c"
      assert sm.version == 3
      refute sm.migrated?
      assert sm.leaf_id == "m2"
      assert sm.by_id |> Map.keys() |> Enum.sort() == ["m1", "m2"]
      assert match?(%Entry.Message{}, sm.by_id["m1"])
      assert sm.by_id["m2"].parent_id == "m1"
    end
  end

  describe "load/1 — fixtures (v1 → migrated)" do
    setup do
      [
        before_compaction: Path.join(@fixture_root, "before-compaction.jsonl"),
        large_session: Path.join(@fixture_root, "large-session.jsonl")
      ]
    end

    test "before-compaction.jsonl loads with full DAG", %{before_compaction: path} do
      assert File.exists?(path), "fixture missing at #{path}"
      assert {:ok, sm} = SessionManager.load(path)

      assert %SessionManager{} = sm
      assert sm.version == 3
      assert sm.migrated?
      assert is_binary(sm.session_id)
      assert sm.cwd =~ "pi-mono"
      assert is_binary(sm.leaf_id)

      # Every body entry is indexed.
      [%Header{} | body] = sm.file_entries
      assert map_size(sm.by_id) == length(body)

      # Every entry has an assigned id and forms a valid linear chain
      # (v1 fixtures have no branching).
      assert_linear_parent_chain(body)

      # Leaf is the last appended body entry.
      last = List.last(body)
      assert sm.leaf_id == entry_id(last)
    end

    test "large-session.jsonl loads with full DAG", %{large_session: path} do
      assert {:ok, sm} = SessionManager.load(path)
      assert sm.version == 3
      assert sm.migrated?

      [%Header{} | body] = sm.file_entries
      assert body != []
      assert map_size(sm.by_id) == length(body)
      assert_linear_parent_chain(body)
    end
  end

  describe "load/1 — v2 → v3 migration" do
    test "renames hookMessage role to custom on Message entries" do
      tmp = scratch("v2.jsonl")

      File.write!(tmp, """
      {"type":"session","version":2,"id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"hookMessage","content":"hello"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t","message":{"role":"user","content":"world"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert sm.version == 3
      assert sm.migrated?
      assert sm.by_id["m1"].message["role"] == "custom"
      assert sm.by_id["m2"].message["role"] == "user"
    end
  end

  describe "load/1 — v1 compaction firstKeptEntryIndex migration" do
    test "rewrites firstKeptEntryIndex (positional) into firstKeptEntryId (id-based)" do
      tmp = scratch("v1-compaction.jsonl")

      File.write!(tmp, """
      {"type":"session","id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","timestamp":"t","message":{"role":"user","content":"a"}}
      {"type":"message","timestamp":"t","message":{"role":"assistant","content":"b"}}
      {"type":"compaction","timestamp":"t","summary":"sum","firstKeptEntryIndex":1,"tokensBefore":42}
      {"type":"message","timestamp":"t","message":{"role":"user","content":"c"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert sm.version == 3
      assert sm.migrated?

      [%Header{} | body] = sm.file_entries
      [_m_a, m_b, comp, _m_c] = body
      assert %Entry.Compaction{} = comp
      # The compaction's firstKeptEntryId now points at the second body
      # entry (originally index 1) — m_b.
      assert comp.first_kept_entry_id == m_b.id
      refute Map.has_key?(comp.extras, "firstKeptEntryIndex")
    end
  end

  describe "get_leaf_entry_id/1 + get_branch/{1,2}" do
    test "empty body session — leaf is nil, branch is []" do
      tmp = scratch("nobody.jsonl")
      File.write!(tmp, ~s({"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}\n))

      assert {:ok, sm} = SessionManager.load(tmp)
      assert SessionManager.get_leaf_entry_id(sm) == nil
      assert SessionManager.get_branch(sm) == []
    end

    test "single-entry session — leaf points at it, branch is [it]" do
      tmp = scratch("one.jsonl")

      File.write!(tmp, """
      {"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"hi"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert SessionManager.get_leaf_entry_id(sm) == "m1"
      assert [%Entry.Message{id: "m1"}] = SessionManager.get_branch(sm)
    end

    test "linear session — branch from leaf returns root→leaf" do
      sm = build_linear(["a", "b", "c", "d"])
      assert SessionManager.get_leaf_entry_id(sm) == "d"
      assert sm |> SessionManager.get_branch() |> Enum.map(& &1.id) == ~w(a b c d)
    end

    test "branch from intermediate id returns root→that id" do
      sm = build_linear(["a", "b", "c", "d"])
      assert sm |> SessionManager.get_branch("b") |> Enum.map(& &1.id) == ~w(a b)
    end

    test "branch from unknown id returns []" do
      sm = build_linear(["a", "b"])
      assert SessionManager.get_branch(sm, "ghost") == []
    end

    test "branch terminates on broken parent chain (orphaned ancestor)" do
      tmp = scratch("orphan.jsonl")

      File.write!(tmp, """
      {"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":"missing","timestamp":"t","message":{"role":"user","content":"x"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t","message":{"role":"user","content":"y"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert sm |> SessionManager.get_branch() |> Enum.map(& &1.id) == ~w(m1 m2)
    end
  end

  describe "path/3 — anchor variants" do
    # Topology: m1 → m2 → m3 → c1(firstKept=m2) → m4 → m5
    # The compaction's kept window is [m2, m3]; everything before
    # firstKeptEntryId (m1) is summarized into c1; m4, m5 are after.
    defp build_with_compaction do
      tmp = scratch("comp.jsonl")

      File.write!(tmp, """
      {"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"u1"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t","message":{"role":"user","content":"u2"}}
      {"type":"message","id":"m3","parentId":"m2","timestamp":"t","message":{"role":"user","content":"u3"}}
      {"type":"compaction","id":"c1","parentId":"m3","timestamp":"t","summary":"s","firstKeptEntryId":"m2","tokensBefore":100}
      {"type":"message","id":"m4","parentId":"c1","timestamp":"t","message":{"role":"user","content":"u4"}}
      {"type":"message","id":"m5","parentId":"m4","timestamp":"t","message":{"role":"user","content":"u5"}}
      """)

      {:ok, sm} = SessionManager.load(tmp)
      sm
    end

    test ":root walks the entire branch" do
      sm = build_with_compaction()

      assert sm |> SessionManager.path(:leaf, to: :root) |> Enum.map(& &1.id) ==
               ~w(m1 m2 m3 c1 m4 m5)
    end

    test ":latest_compaction stops at the latest compaction's first_kept_entry_id (inclusive)" do
      sm = build_with_compaction()

      # m2 is firstKeptEntryId; result includes the kept window
      # [m2, m3], the compaction c1, and post-compaction tail [m4, m5].
      assert sm |> SessionManager.path(:leaf, to: :latest_compaction) |> Enum.map(& &1.id) ==
               ~w(m2 m3 c1 m4 m5)
    end

    test ":latest_compaction falls back to root when no compaction exists" do
      sm = build_linear(~w(a b c))

      assert sm |> SessionManager.path(:leaf, to: :latest_compaction) |> Enum.map(& &1.id) ==
               ~w(a b c)
    end

    test "to: <id> stops at that id (inclusive)" do
      sm = build_with_compaction()
      assert sm |> SessionManager.path(:leaf, to: "m4") |> Enum.map(& &1.id) == ~w(m4 m5)
    end

    test "explicit leaf id" do
      sm = build_with_compaction()
      assert sm |> SessionManager.path("m3", to: :root) |> Enum.map(& &1.id) == ~w(m1 m2 m3)
    end

    test "nil leaf returns []" do
      sm = build_linear(~w(a b))
      assert SessionManager.path(sm, nil, to: :root) == []
    end
  end

  describe "get_entries/1" do
    test "empty body session returns []" do
      tmp = scratch("nobody-entries.jsonl")
      File.write!(tmp, ~s({"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}\n))

      assert {:ok, sm} = SessionManager.load(tmp)
      assert SessionManager.get_entries(sm) == []
    end

    test "returns body entries in file order, header excluded" do
      tmp = scratch("entries.jsonl")

      File.write!(tmp, """
      {"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"a"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t","message":{"role":"assistant","content":"b"}}
      """)

      assert {:ok, sm} = SessionManager.load(tmp)
      assert sm |> SessionManager.get_entries() |> Enum.map(& &1.id) == ~w(m1 m2)
    end
  end

  describe "find_common_ancestor/3" do
    test "nil old_leaf_id returns nil" do
      sm = build_linear(["a", "b", "c"])
      assert SessionManager.find_common_ancestor(sm, nil, "c") == nil
    end

    test "linear session — deepest shared id is the older leaf" do
      sm = build_linear(["a", "b", "c", "d"])
      # old at "b", target at "d" — both share root→b, deepest common is b.
      assert SessionManager.find_common_ancestor(sm, "b", "d") == "b"
    end

    test "forked sessions — common ancestor is the branch point" do
      # Tree:
      #         a
      #         |
      #         b   ← branch point
      #        / \\
      #       c   x
      #       |   |
      #       d   y
      sm = build_forked()
      assert SessionManager.find_common_ancestor(sm, "d", "y") == "b"
    end

    test "multi-level fork — common ancestor is the deepest shared node" do
      # Tree (b forked, then c forked):
      #     a─b─c─d─e   (old leaf: e)
      #         └─x─y   (target leaf: y, branch from c)
      sm = build_multi_fork()
      assert SessionManager.find_common_ancestor(sm, "e", "y") == "c"
    end

    test "unknown target id returns nil" do
      sm = build_linear(["a", "b"])
      assert SessionManager.find_common_ancestor(sm, "b", "ghost") == nil
    end

    test "disjoint roots return nil" do
      sm = build_disjoint()
      assert SessionManager.find_common_ancestor(sm, "a2", "b2") == nil
    end
  end

  describe "collect_entries_for_branch_summary/3" do
    test "nil old_leaf_id returns {[], nil}" do
      sm = build_linear(["a", "b", "c"])
      assert SessionManager.collect_entries_for_branch_summary(sm, nil, "c") == {[], nil}
    end

    test "same old and target: common ancestor is the entry itself, entries list is empty" do
      sm = build_linear(["a", "b", "c"])
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "c", "c")
      assert ancestor_id == "c"
      assert entries == []
    end

    test "linear session — navigating from leaf to ancestor: entries between ancestor and old leaf" do
      # a→b→c→d, old=d, target=b → common=b, entries=[c, d]
      sm = build_linear(["a", "b", "c", "d"])
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "d", "b")
      assert ancestor_id == "b"
      assert Enum.map(entries, & &1.id) == ["c", "d"]
    end

    test "linear session — navigating to root: all entries after root included" do
      # a→b→c→d, old=d, target=a → common=a, entries=[b, c, d]
      sm = build_linear(["a", "b", "c", "d"])
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "d", "a")
      assert ancestor_id == "a"
      assert Enum.map(entries, & &1.id) == ["b", "c", "d"]
    end

    test "forked session — navigating across branches: entries from common ancestor to old leaf" do
      # a→b→c→d  (old leaf: d)
      #    └→x→y  (target leaf: y)
      # common ancestor: b; entries from b to d (exclusive b): [c, d]
      sm = build_forked()
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "d", "y")
      assert ancestor_id == "b"
      assert Enum.map(entries, & &1.id) == ["c", "d"]
    end

    test "multi-level fork: entries from deepest common ancestor to old leaf" do
      # a→b→c→d→e  (old leaf: e)
      #       └→x→y  (target, branch from c)
      # common ancestor: c; entries: [d, e]
      sm = build_multi_fork()
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "e", "y")
      assert ancestor_id == "c"
      assert Enum.map(entries, & &1.id) == ["d", "e"]
    end

    test "disjoint trees: common ancestor is nil, all entries from old leaf to root included" do
      sm = build_disjoint()
      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "a2", "b2")
      assert ancestor_id == nil
      assert Enum.map(entries, & &1.id) == ["a1", "a2"]
    end

    test "entries are returned in root→leaf (chronological) order" do
      sm = build_linear(["a", "b", "c", "d", "e"])
      {entries, _} = SessionManager.collect_entries_for_branch_summary(sm, "e", "a")
      assert Enum.map(entries, & &1.id) == ["b", "c", "d", "e"]
    end

    test "compaction entries are included (does not stop at compaction boundary)" do
      # Build a tree that includes a compaction entry between messages
      by_id = %{
        "m1" => %Entry.Message{
          id: "m1",
          parent_id: nil,
          timestamp: "t",
          message: %{"role" => "user", "content" => "m1"}
        },
        "cmp" => %Entry.Compaction{
          id: "cmp",
          parent_id: "m1",
          timestamp: "t",
          summary: "compacted",
          tokens_before: 100,
          first_kept_entry_id: "m1"
        },
        "m2" => %Entry.Message{
          id: "m2",
          parent_id: "cmp",
          timestamp: "t",
          message: %{"role" => "user", "content" => "m2"}
        }
      }

      sm = %SessionManager{cwd: "/c", session_id: "s", version: 3, by_id: by_id}

      {entries, ancestor_id} = SessionManager.collect_entries_for_branch_summary(sm, "m2", "m1")
      assert ancestor_id == "m1"
      # compaction entry must be included
      assert Enum.map(entries, & &1.id) == ["cmp", "m2"]
    end
  end

  describe "add_entry/3" do
    test "advances leaf, indexes the entry, links parent_id to old leaf" do
      sm = empty_sm()

      {sm, entry1} = SessionManager.add_entry(sm, msg("a"))
      assert SessionManager.get_leaf_entry_id(sm) == entry1.id
      assert sm.by_id[entry1.id].parent_id == nil

      {sm, entry2} = SessionManager.add_entry(sm, msg("b"))
      assert SessionManager.get_leaf_entry_id(sm) == entry2.id
      assert sm.by_id[entry2.id].parent_id == entry1.id
      assert sm |> SessionManager.get_branch() |> Enum.map(& &1.id) == [entry1.id, entry2.id]
    end

    test "uses an explicit :id when provided" do
      sm = empty_sm()
      {sm, entry} = SessionManager.add_entry(sm, msg("hi"), id: "fixed")
      assert entry.id == "fixed"
      assert sm.leaf_id == "fixed"
      assert sm.by_id["fixed"].id == "fixed"
    end

    test "fills timestamp when entry has none, preserves existing one" do
      sm = empty_sm()

      {sm, _entry} = SessionManager.add_entry(sm, msg("t1"))
      assert is_binary(List.last(sm.file_entries).timestamp)

      {sm, _entry2} = SessionManager.add_entry(sm, %{msg("t2") | timestamp: "fixed-ts"})
      assert List.last(sm.file_entries).timestamp == "fixed-ts"
    end
  end

  defp empty_sm, do: %SessionManager{cwd: "/c", session_id: "s", version: 3}

  defp msg(text) do
    %Entry.Message{
      id: nil,
      parent_id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => text}
    }
  end

  # Build a SessionManager whose by_id encodes branches that the
  # JSONL-only loader can't express. Bypasses load/1 by constructing
  # the struct directly, which is fine for traversal-level tests.
  defp build_branched(entries) do
    by_id =
      Map.new(entries, fn {id, parent} ->
        {id, %Entry.Message{id: id, parent_id: parent, timestamp: "t", message: %{"role" => "user", "content" => id}}}
      end)

    %SessionManager{cwd: "/c", session_id: "s", version: 3, by_id: by_id}
  end

  defp build_forked do
    build_branched([
      {"a", nil},
      {"b", "a"},
      {"c", "b"},
      {"d", "c"},
      {"x", "b"},
      {"y", "x"}
    ])
  end

  defp build_multi_fork do
    build_branched([
      {"a", nil},
      {"b", "a"},
      {"c", "b"},
      {"d", "c"},
      {"e", "d"},
      {"x", "c"},
      {"y", "x"}
    ])
  end

  defp build_disjoint do
    build_branched([
      {"a1", nil},
      {"a2", "a1"},
      {"b1", nil},
      {"b2", "b1"}
    ])
  end

  defp build_linear(ids) do
    lines =
      ids
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {id, idx} ->
        parent = if idx == 0, do: "null", else: ~s("#{Enum.at(ids, idx - 1)}")

        ~s({"type":"message","id":"#{id}","parentId":#{parent},"timestamp":"t","message":{"role":"user","content":"#{id}"}})
      end)

    tmp = scratch("linear.jsonl")
    File.write!(tmp, ~s({"type":"session","version":3,"id":"s","timestamp":"t","cwd":"/c"}\n) <> lines <> "\n")
    {:ok, sm} = SessionManager.load(tmp)
    sm
  end

  defp scratch(name) do
    path = Path.join(System.tmp_dir!(), "smt-#{System.unique_integer([:positive])}-#{name}")
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp assert_linear_parent_chain([first | rest]) do
    assert is_binary(entry_id(first))
    assert entry_parent(first) == nil

    Enum.reduce(rest, entry_id(first), fn e, prev_id ->
      assert entry_parent(e) == prev_id
      assert is_binary(entry_id(e))
      entry_id(e)
    end)
  end

  defp entry_id(%Entry.Passthrough{raw: r}), do: r["id"]
  defp entry_id(e), do: Map.get(e, :id)

  defp entry_parent(%Entry.Passthrough{raw: r}), do: r["parentId"]
  defp entry_parent(e), do: Map.get(e, :parent_id)
end
