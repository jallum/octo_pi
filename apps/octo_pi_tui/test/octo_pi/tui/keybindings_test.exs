defmodule OctoPi.TUI.KeybindingsTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.{Key, Keybindings}

  describe "new/0" do
    test "creates manager with default bindings" do
      kb = Keybindings.new()
      assert is_map(kb.bindings)
      assert map_size(kb.bindings) > 0
    end
  end

  describe "new/1 with user overrides" do
    test "user bindings override defaults" do
      kb = Keybindings.new(%{"tui.input.submit" => ["ctrl+m"]})
      keys = Keybindings.get_keys(kb, "tui.input.submit")
      assert keys == ["ctrl+m"]
    end

    test "ignores unknown binding names" do
      kb = Keybindings.new(%{"unknown.action" => ["x"]})
      assert Keybindings.get_keys(kb, "unknown.action") == []
    end
  end

  describe "matches?/3" do
    test "matches default enter binding for submit" do
      kb = Keybindings.new()
      key = %Key{key: :enter}
      assert Keybindings.matches?(kb, key, "tui.input.submit")
    end

    test "matches escape for select cancel" do
      kb = Keybindings.new()
      key = %Key{key: :escape}
      assert Keybindings.matches?(kb, key, "tui.select.cancel")
    end

    test "does not match unrelated key" do
      kb = Keybindings.new()
      key = %Key{key: ?a}
      refute Keybindings.matches?(kb, key, "tui.input.submit")
    end

    test "matches user-overridden binding" do
      kb = Keybindings.new(%{"tui.input.submit" => ["ctrl+m"]})
      key = %Key{key: ?m, modifiers: [:ctrl]}
      assert Keybindings.matches?(kb, key, "tui.input.submit")
    end

    test "matches any of multiple keys" do
      kb = Keybindings.new()
      left = %Key{key: :left}
      ctrl_b = %Key{key: ?b, modifiers: [:ctrl]}
      assert Keybindings.matches?(kb, left, "tui.editor.cursorLeft")
      assert Keybindings.matches?(kb, ctrl_b, "tui.editor.cursorLeft")
    end
  end

  describe "get_keys/2" do
    test "returns default keys for a binding" do
      kb = Keybindings.new()
      keys = Keybindings.get_keys(kb, "tui.input.submit")
      assert "enter" in keys
    end

    test "returns empty list for unknown binding" do
      kb = Keybindings.new()
      assert Keybindings.get_keys(kb, "nonexistent") == []
    end
  end

  describe "conflicts/1" do
    test "no conflicts with defaults" do
      kb = Keybindings.new()
      assert Keybindings.conflicts(kb) == []
    end

    test "detects user-introduced conflicts" do
      kb =
        Keybindings.new(%{
          "tui.input.submit" => ["ctrl+x"],
          "tui.input.copy" => ["ctrl+x"]
        })

      conflicts = Keybindings.conflicts(kb)
      assert conflicts != []
      conflict = hd(conflicts)
      assert conflict.key == "ctrl+x"
      assert "tui.input.submit" in conflict.bindings
      assert "tui.input.copy" in conflict.bindings
    end
  end

  describe "set_user_bindings/2" do
    test "rebuilds with new user bindings" do
      kb = Keybindings.new()
      kb = Keybindings.set_user_bindings(kb, %{"tui.input.submit" => ["space"]})
      keys = Keybindings.get_keys(kb, "tui.input.submit")
      assert keys == ["space"]
    end
  end
end
