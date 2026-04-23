defmodule OctoPi.TUI.Components.SelectListTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SelectList
  alias OctoPi.TUI.Key

  describe "render/2" do
    test "renders each item on its own line" do
      lines = SelectList.render(%SelectList{items: ["a", "b", "c"]}, 80)
      assert length(lines) == 3
    end

    test "marks the selected item with reverse-video prefix" do
      [l0, l1, _] = SelectList.render(%SelectList{items: ["a", "b", "c"], selected: 0}, 80)
      assert l0 =~ "\e[7m"
      refute l1 =~ "\e[7m"
    end

    test "empty list shows a sentinel" do
      assert ["(empty)"] = SelectList.render(%SelectList{items: []}, 80)
    end
  end

  describe "handle_key/2" do
    test "down moves selection forward" do
      s = %SelectList{items: ["a", "b", "c"], selected: 0}
      assert %SelectList{selected: 1} = SelectList.handle_key(s, %Key{key: :down})
    end

    test "down wraps at end" do
      s = %SelectList{items: ["a", "b", "c"], selected: 2}
      assert %SelectList{selected: 0} = SelectList.handle_key(s, %Key{key: :down})
    end

    test "up moves selection backward" do
      s = %SelectList{items: ["a", "b", "c"], selected: 2}
      assert %SelectList{selected: 1} = SelectList.handle_key(s, %Key{key: :up})
    end

    test "up wraps at start" do
      s = %SelectList{items: ["a", "b", "c"], selected: 0}
      assert %SelectList{selected: 2} = SelectList.handle_key(s, %Key{key: :up})
    end

    test "Enter yields {:select, item}" do
      s = %SelectList{items: ["a", "b", "c"], selected: 1}
      assert {_, [{:select, "b"}]} = SelectList.handle_key(s, %Key{key: :enter})
    end

    test "Escape yields :cancel" do
      s = %SelectList{items: ["a"], selected: 0}
      assert {_, [:cancel]} = SelectList.handle_key(s, %Key{key: :escape})
    end

    test "empty list is a no-op for all keys" do
      s = %SelectList{items: []}
      assert ^s = SelectList.handle_key(s, %Key{key: :up})
      assert ^s = SelectList.handle_key(s, %Key{key: :enter})
    end
  end
end
