defmodule OctoPi.TUI.Components.ContainerTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Container
  alias OctoPi.TUI.Components.Text

  describe "new/0" do
    test "creates empty container" do
      c = Container.new()
      assert c.children == []
    end
  end

  describe "new/1" do
    test "creates container with initial children" do
      t1 = %Text{content: "hello"}
      t2 = %Text{content: "world"}
      c = Container.new([t1, t2])
      assert c.children == [t1, t2]
    end
  end

  describe "add_child/2" do
    test "appends a child" do
      t = %Text{content: "hi"}
      c = Container.new() |> Container.add_child(t)
      assert c.children == [t]
    end

    test "preserves order" do
      t1 = %Text{content: "first"}
      t2 = %Text{content: "second"}
      c = Container.new() |> Container.add_child(t1) |> Container.add_child(t2)
      assert c.children == [t1, t2]
    end
  end

  describe "remove_child/2" do
    test "removes a child by index" do
      t1 = %Text{content: "a"}
      t2 = %Text{content: "b"}
      t3 = %Text{content: "c"}
      c = Container.new([t1, t2, t3]) |> Container.remove_child(1)
      assert c.children == [t1, t3]
    end

    test "returns unchanged container for out-of-bounds index" do
      c = Container.new([%Text{content: "a"}])
      assert Container.remove_child(c, 5) == c
    end
  end

  describe "clear/1" do
    test "removes all children" do
      c = Container.new([%Text{content: "a"}, %Text{content: "b"}])
      assert Container.clear(c).children == []
    end
  end

  describe "update_child/3" do
    test "replaces child at index" do
      t1 = %Text{content: "old"}
      t2 = %Text{content: "new"}
      c = Container.new([t1]) |> Container.update_child(0, t2)
      assert c.children == [t2]
    end
  end

  describe "render/2" do
    test "empty container renders empty list" do
      assert Container.render(Container.new(), 80) == []
    end

    test "single child renders its lines" do
      c = Container.new([%Text{content: "hello"}])
      assert Container.render(c, 80) == ["hello"]
    end

    test "multiple children stack vertically" do
      c = Container.new([%Text{content: "line 1"}, %Text{content: "line 2"}])
      assert Container.render(c, 80) == ["line 1", "line 2"]
    end

    test "multi-line children concatenate correctly" do
      c = Container.new([%Text{content: "a\nb"}, %Text{content: "c\nd"}])
      assert Container.render(c, 80) == ["a", "b", "c", "d"]
    end

    test "nested containers flatten lines" do
      inner = Container.new([%Text{content: "inner"}])
      outer = Container.new([%Text{content: "outer"}, inner])
      assert Container.render(outer, 80) == ["outer", "inner"]
    end

    test "passes width to children" do
      c = Container.new([%Text{content: String.duplicate("x", 100)}])
      [line] = Container.render(c, 10)
      assert String.length(line) == 10
    end
  end

  describe "child_count/1" do
    test "returns number of children" do
      assert Container.child_count(Container.new()) == 0
      assert Container.child_count(Container.new([%Text{content: "a"}])) == 1
    end
  end
end
