defmodule OctoPi.Coder.SessionManager.GetTreeTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.TreeNode
  alias OctoPi.Coder.SessionManager

  defp new_session do
    tmp = Path.join(System.tmp_dir!(), "sm-tree-#{System.unique_integer()}.jsonl")
    header = ~s({"type":"session","version":3,"id":"s1","timestamp":"t","cwd":"/c"}\n)
    File.write!(tmp, header)
    {:ok, sm} = SessionManager.load(tmp)
    sm
  end

  defp add_user(sm, content) do
    SessionManager.add_entry(sm, %Entry.Message{
      id: nil,
      timestamp: nil,
      message: %{"role" => "user", "content" => content}
    })
  end

  defp add_assistant(sm, content) do
    SessionManager.add_entry(sm, %Entry.Message{
      id: nil,
      timestamp: nil,
      message: %{"role" => "assistant", "content" => [%{"type" => "text", "text" => content}]}
    })
  end

  describe "get_tree/1" do
    test "returns empty list for empty session" do
      sm = new_session()
      assert SessionManager.get_tree(sm) == []
    end

    test "returns single root for linear session" do
      sm = new_session()
      {sm, e1} = add_user(sm, "1")
      {sm, e2} = add_assistant(sm, "2")
      {sm, e3} = add_user(sm, "3")

      tree = SessionManager.get_tree(sm)
      assert length(tree) == 1

      root = hd(tree)
      assert root.entry.id == e1.id
      assert length(root.children) == 1

      node2 = hd(root.children)
      assert node2.entry.id == e2.id
      assert length(node2.children) == 1

      node3 = hd(node2.children)
      assert node3.entry.id == e3.id
      assert node3.children == []
    end

    test "returns tree with two branches after set_leaf" do
      sm = new_session()
      {sm, e1} = add_user(sm, "1")
      {sm, e2} = add_assistant(sm, "2")
      {sm, e3} = add_user(sm, "3")

      # Branch from e2 and add e4 as sibling of e3
      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, e4} = add_user(sm, "4-branch")

      tree = SessionManager.get_tree(sm)
      assert length(tree) == 1

      root = hd(tree)
      assert root.entry.id == e1.id

      node2 = hd(root.children)
      assert node2.entry.id == e2.id
      assert length(node2.children) == 2

      child_ids = Enum.map(node2.children, & &1.entry.id)
      assert Enum.sort(child_ids) == Enum.sort([e3.id, e4.id])
    end

    test "handles multiple branches at same point" do
      sm = new_session()
      {sm, _e1} = add_user(sm, "root")
      {sm, e2} = add_assistant(sm, "response")

      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, eA} = add_user(sm, "branch-A")

      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, eB} = add_user(sm, "branch-B")

      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, eC} = add_user(sm, "branch-C")

      tree = SessionManager.get_tree(sm)
      node2 = hd(tree).children |> hd()
      assert node2.entry.id == e2.id
      assert length(node2.children) == 3

      branch_ids = Enum.map(node2.children, & &1.entry.id)
      assert Enum.sort(branch_ids) == Enum.sort([eA.id, eB.id, eC.id])
    end

    test "handles deep branching" do
      sm = new_session()
      {sm, _e1} = add_user(sm, "1")
      {sm, e2} = add_assistant(sm, "2")
      {sm, e3} = add_user(sm, "3")
      {sm, _e4} = add_assistant(sm, "4")

      # Branch from e2: e2 -> e5 -> e6
      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, e5} = add_user(sm, "5")
      {sm, _e6} = add_assistant(sm, "6")

      # Branch from e5: e5 -> e7
      sm = SessionManager.set_leaf(sm, e5.id)
      {sm, _e7} = add_user(sm, "7")

      tree = SessionManager.get_tree(sm)

      node2 = hd(tree).children |> hd()
      assert length(node2.children) == 2

      node5 = Enum.find(node2.children, &(&1.entry.id == e5.id))
      assert length(node5.children) == 2

      node3 = Enum.find(node2.children, &(&1.entry.id == e3.id))
      assert length(node3.children) == 1
    end

    test "children are sorted by timestamp ascending" do
      sm = new_session()
      {sm, _e1} = add_user(sm, "root")
      {sm, e2} = add_assistant(sm, "2")

      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, _eA} = add_user(sm, "A")

      sm = SessionManager.set_leaf(sm, e2.id)
      {sm, _eB} = add_user(sm, "B")

      tree = SessionManager.get_tree(sm)
      node2 = hd(tree).children |> hd()
      timestamps = Enum.map(node2.children, & &1.entry.timestamp)
      assert timestamps == Enum.sort(timestamps)
    end

    test "nodes have nil label and nil label_timestamp by default" do
      sm = new_session()
      {sm, _e1} = add_user(sm, "1")

      tree = SessionManager.get_tree(sm)
      root = hd(tree)
      assert root.label == nil
      assert root.label_timestamp == nil
    end

    test "labels are resolved on tree nodes" do
      sm = new_session()
      {sm, e1} = add_user(sm, "1")
      {sm, label_entry} = SessionManager.append_label_change(sm, e1.id, "checkpoint")

      tree = SessionManager.get_tree(sm)
      root = hd(tree)
      assert root.entry.id == e1.id
      assert root.label == "checkpoint"
      assert root.label_timestamp == label_entry.timestamp
    end

    test "labels are included on nodes for multi-entry session" do
      sm = new_session()
      {sm, e1} = add_user(sm, "hello")

      {sm, e2} = add_assistant(sm, "hi")

      {sm, l1} = SessionManager.append_label_change(sm, e1.id, "start")
      {sm, l2} = SessionManager.append_label_change(sm, e2.id, "response")

      tree = SessionManager.get_tree(sm)
      root = hd(tree)
      assert root.entry.id == e1.id
      assert root.label == "start"
      assert root.label_timestamp == l1.timestamp

      node2 = Enum.find(root.children, &(&1.entry.id == e2.id))
      assert node2 != nil
      assert node2.label == "response"
      assert node2.label_timestamp == l2.timestamp
    end

    test "last label wins on tree node" do
      sm = new_session()
      {sm, e1} = add_user(sm, "hello")
      {sm, _} = SessionManager.append_label_change(sm, e1.id, "first")
      {sm, _} = SessionManager.append_label_change(sm, e1.id, "second")
      {sm, l3} = SessionManager.append_label_change(sm, e1.id, "third")

      tree = SessionManager.get_tree(sm)
      root = hd(tree)
      assert root.label == "third"
      assert root.label_timestamp == l3.timestamp
    end

    test "cleared label is absent on tree node" do
      sm = new_session()
      {sm, e1} = add_user(sm, "hello")
      {sm, _} = SessionManager.append_label_change(sm, e1.id, "checkpoint")
      {sm, _} = SessionManager.append_label_change(sm, e1.id, nil)

      tree = SessionManager.get_tree(sm)
      root = hd(tree)
      assert root.entry.id == e1.id
      assert root.label == nil
      assert root.label_timestamp == nil
    end

    test "returned nodes are TreeNode structs" do
      sm = new_session()
      {sm, _e1} = add_user(sm, "hello")

      tree = SessionManager.get_tree(sm)
      assert match?([%TreeNode{}], tree)
    end
  end
end
