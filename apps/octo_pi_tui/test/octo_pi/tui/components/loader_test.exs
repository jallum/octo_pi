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
      assert line =~ "X" or line =~ "Y"
    end

    test "does not add a separate cancel-hint line (upstream parity: hint is inline in message)" do
      loader = Loader.new(message: "Working... (Esc to cancel)", cancellable: true)
      lines = Loader.render(loader, 80)
      joined = Enum.join(lines, "\n")
      esc_count = joined |> String.split("Esc") |> length() |> Kernel.-(1)
      assert esc_count == 1, "expected exactly 1 'Esc' occurrence, got #{esc_count}: #{inspect(lines)}"
    end

    test "no cancel hint rendered when cancellable but message has none" do
      loader = Loader.new(message: "Working...", cancellable: true)
      lines = Loader.render(loader, 80)
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
