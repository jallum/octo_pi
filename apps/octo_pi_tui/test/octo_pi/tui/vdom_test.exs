defmodule OctoPi.TUI.VDOMTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.VDOM

  describe "VNode types" do
    test "VText struct" do
      node = %VDOM.VText{text: "hello", width: 5}
      assert node.text == "hello"
      assert node.width == 5
      assert VDOM.vnode_term?(node)
    end

    test "VLines struct" do
      node = %VDOM.VLines{lines: ["line1", "line2"]}
      assert node.lines == ["line1", "line2"]
      assert VDOM.vnode_term?(node)
    end

    test "VFlow struct" do
      node = %VDOM.VFlow{children: []}
      assert VDOM.vnode_term?(node)
    end

    test "VRow struct" do
      node = %VDOM.VRow{children: []}
      assert VDOM.vnode_term?(node)
    end

    test "VBox struct" do
      node = %VDOM.VBox{border?: true, padding_x: 1, padding_y: 1, children: []}
      assert node.border?
      assert node.padding_x == 1
      assert VDOM.vnode_term?(node)
    end

    test "VZone struct" do
      node = %VDOM.VZone{type: :output, id: "test", children: []}
      assert node.type == :output
      assert node.id == "test"
      assert VDOM.vnode_term?(node)
    end

    test "VMemo struct" do
      node = %VDOM.VMemo{key: :test, thunk: fn -> [] end, cell: nil}
      assert node.key == :test
      assert is_function(node.thunk)
      assert VDOM.vnode_term?(node)
    end

    test "VHole struct" do
      node = %VDOM.VHole{slot_id: :test}
      assert node.slot_id == :test
      assert VDOM.vnode_term?(node)
    end

    test "VCursor struct" do
      node = %VDOM.VCursor{}
      assert VDOM.vnode_term?(node)
    end

    test "vnode_term? rejects non-structs" do
      refute VDOM.vnode_term?("string")
      refute VDOM.vnode_term?(123)
      refute VDOM.vnode_term?(%{a: 1})
    end
  end
end
