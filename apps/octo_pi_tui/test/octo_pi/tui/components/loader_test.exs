defmodule OctoPi.TUI.Components.LoaderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Loader
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  defp theme, do: Theme.load_builtin(:dark, :truecolor)

  describe "new/1" do
    test "creates loader with default message" do
      loader = Loader.new()
      assert loader.message == "Loading..."
      assert loader.frame == 0
    end

    test "creates loader with custom message" do
      loader = Loader.new(message: "Thinking...")
      assert loader.message == "Thinking..."
    end

    test "creates loader with custom frames" do
      loader = Loader.new(frames: ["a", "b"])
      assert loader.frames == ["a", "b"]
    end

    test "creates loader with cancellable option" do
      loader = Loader.new(cancellable: true)
      assert loader.cancellable == true
    end
  end

  describe "render/2" do
    test "renders spinner frame and message" do
      loader = Loader.new()
      [blank, line] = Loader.render(loader, 40)
      assert blank == ""
      assert line =~ "Loading..."
    end

    test "renders current animation frame" do
      loader = Loader.new(frames: ["X", "Y"])
      [_blank, line] = Loader.render(loader, 40)
      assert line =~ "X"

      loader = Loader.advance_frame(loader)
      [_blank, line] = Loader.render(loader, 40)
      assert line =~ "Y"
    end

    test "renders cancel hint when cancellable" do
      loader = Loader.new(cancellable: true)
      lines = Loader.render(loader, 40)
      assert Enum.any?(lines, &(&1 =~ "Esc"))
    end

    test "no cancel hint when not cancellable" do
      loader = Loader.new(cancellable: false)
      lines = Loader.render(loader, 40)
      refute Enum.any?(lines, &(&1 =~ "Esc"))
    end

    test "renders with theme colors" do
      loader = Loader.new()
      theme = theme()
      lines = Loader.render(loader, 40, theme)
      assert is_list(lines)
      assert length(lines) >= 2
    end
  end

  describe "advance_frame/1" do
    test "cycles through frames" do
      loader = Loader.new(frames: ["a", "b", "c"])
      assert loader.frame == 0

      loader = Loader.advance_frame(loader)
      assert loader.frame == 1

      loader = Loader.advance_frame(loader)
      assert loader.frame == 2

      loader = Loader.advance_frame(loader)
      assert loader.frame == 0
    end

    test "handles single frame" do
      loader = Loader.new(frames: ["X"])
      loader = Loader.advance_frame(loader)
      assert loader.frame == 0
    end
  end

  describe "set_message/2" do
    test "updates the message" do
      loader = Loader.new(message: "old")
      loader = Loader.set_message(loader, "new")
      assert loader.message == "new"
    end
  end

  describe "handle_key/2" do
    test "escape on cancellable emits :cancel" do
      loader = Loader.new(cancellable: true)
      escape = %Key{key: :escape}
      assert {^loader, [:cancel]} = Loader.handle_key(loader, escape)
    end

    test "escape on non-cancellable is ignored" do
      loader = Loader.new(cancellable: false)
      escape = %Key{key: :escape}
      assert ^loader = Loader.handle_key(loader, escape)
    end

    test "other keys are ignored" do
      loader = Loader.new(cancellable: true)
      key = %Key{key: ?a}
      assert ^loader = Loader.handle_key(loader, key)
    end
  end
end
