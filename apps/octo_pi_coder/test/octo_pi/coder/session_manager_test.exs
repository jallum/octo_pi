defmodule OctoPi.Coder.SessionManagerTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Header
  alias OctoPi.Coder.SessionManager

  @fixture_root Path.expand(
                  "../../../../../tmp/pi-mono/packages/coding-agent/test/fixtures",
                  __DIR__
                )

  describe "load/1 — error paths" do
    test "missing file returns :enoent" do
      assert {:error, :enoent} = SessionManager.load(Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}.jsonl"))
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
      assert Map.keys(sm.by_id) |> Enum.sort() == ["m1", "m2"]
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
      assert length(body) > 0
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
      assert SessionManager.get_branch(sm) |> Enum.map(& &1.id) == ~w(a b c d)
    end

    test "branch from intermediate id returns root→that id" do
      sm = build_linear(["a", "b", "c", "d"])
      assert SessionManager.get_branch(sm, "b") |> Enum.map(& &1.id) == ~w(a b)
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
      assert SessionManager.get_branch(sm) |> Enum.map(& &1.id) == ~w(m1 m2)
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

  describe "fork/4" do
    test "missing source returns :enoent" do
      assert {:error, :enoent} =
               SessionManager.fork(
                 Path.join(System.tmp_dir!(), "nope-#{System.unique_integer()}.jsonl"),
                 "/c2",
                 System.tmp_dir!()
               )
    end

    test "copies entries verbatim into a new file with rewritten header" do
      src = scratch("fork-src.jsonl")

      File.write!(src, """
      {"type":"session","version":3,"id":"src-id","timestamp":"src-ts","cwd":"/orig"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t1","message":{"role":"user","content":"a"}}
      {"type":"message","id":"m2","parentId":"m1","timestamp":"t2","message":{"role":"assistant","content":"b"}}
      """)

      target_dir = Path.join(System.tmp_dir!(), "fork-dst-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(target_dir) end)

      assert {:ok, forked} = SessionManager.fork(src, "/new-cwd", target_dir, id: "new-id", timestamp: "2026-01-01T00:00:00Z")
      assert forked.session_id == "new-id"
      assert forked.cwd == "/new-cwd"
      assert forked.parent_session == src
      assert forked.version == 3

      # Same body, same ids, same parent_id chain
      assert forked.by_id["m1"].parent_id == nil
      assert forked.by_id["m2"].parent_id == "m1"
      assert forked.leaf_id == "m2"

      # Original file untouched
      [orig_header | _] = src |> OctoPi.Coder.SessionStore.read_entries() |> Enum.to_list()
      assert orig_header.id == "src-id"
      assert orig_header.cwd == "/orig"
      refute orig_header.parent_session
    end

    test "forked file is independently loadable" do
      src = scratch("fork-roundtrip.jsonl")

      File.write!(src, """
      {"type":"session","version":3,"id":"a","timestamp":"t","cwd":"/c"}
      {"type":"message","id":"m1","parentId":null,"timestamp":"t","message":{"role":"user","content":"x"}}
      """)

      target_dir = Path.join(System.tmp_dir!(), "fork-rt-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(target_dir) end)

      assert {:ok, forked} = SessionManager.fork(src, "/c2", target_dir)
      reloaded = SessionManager.load(forked.session_file)
      assert {:ok, sm} = reloaded
      assert sm.session_id == forked.session_id
      assert sm.parent_session == src
      assert Map.keys(sm.by_id) == ["m1"]
    end
  end

  describe "add_entry/3" do
    test "advances leaf, indexes the entry, links parent_id to old leaf" do
      sm = empty_sm()

      {sm, id1} = SessionManager.add_entry(sm, msg("a"))
      assert SessionManager.get_leaf_entry_id(sm) == id1
      assert sm.by_id[id1].parent_id == nil

      {sm, id2} = SessionManager.add_entry(sm, msg("b"))
      assert SessionManager.get_leaf_entry_id(sm) == id2
      assert sm.by_id[id2].parent_id == id1
      assert SessionManager.get_branch(sm) |> Enum.map(& &1.id) == [id1, id2]
    end

    test "uses an explicit :id when provided" do
      sm = empty_sm()
      {sm, id} = SessionManager.add_entry(sm, msg("hi"), id: "fixed")
      assert id == "fixed"
      assert sm.leaf_id == "fixed"
      assert sm.by_id["fixed"].id == "fixed"
    end

    test "fills timestamp when entry has none, preserves existing one" do
      sm = empty_sm()

      {sm, _id} = SessionManager.add_entry(sm, msg("t1"))
      assert is_binary(List.last(sm.file_entries).timestamp)

      {sm, _id2} = SessionManager.add_entry(sm, %{msg("t2") | timestamp: "fixed-ts"})
      assert List.last(sm.file_entries).timestamp == "fixed-ts"
    end

    test "persists each entry to the attached SessionStore" do
      tmp = Path.join(System.tmp_dir!(), "smt-store-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)

      {:ok, store} = OctoPi.Coder.SessionStore.open(id: "rt", cwd: tmp, root: tmp)
      path = OctoPi.Coder.SessionStore.path(store)

      sm = empty_sm()
      {sm, _id1} = SessionManager.add_entry(sm, msg("x"), store: store)
      {sm, _id2} = SessionManager.add_entry(sm, msg("y"), store: store)

      :ok = OctoPi.Coder.SessionStore.close(store)
      reread = path |> OctoPi.Coder.SessionStore.read_entries() |> Enum.to_list()

      [%OctoPi.Coder.Session.Header{}, m1, m2] = reread
      [in_mem1, in_mem2] = sm.file_entries
      assert m1.id == in_mem1.id
      assert m2.id == in_mem2.id
      assert m1.parent_id == nil
      assert m2.parent_id == m1.id
      assert m1.message["content"] == "x"
      assert m2.message["content"] == "y"
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

    rest
    |> Enum.reduce(entry_id(first), fn e, prev_id ->
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
