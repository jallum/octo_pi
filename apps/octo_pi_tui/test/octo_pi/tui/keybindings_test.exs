defmodule OctoPi.TUI.KeybindingsTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings

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

  describe "no-eviction of defaults (upstream keybindings.test.ts parity)" do
    test "sibling default preserved when a binding is rebound" do
      kb = Keybindings.new(%{"tui.input.submit" => ["enter", "ctrl+enter"]})
      assert Keybindings.get_keys(kb, "tui.input.submit") == ["enter", "ctrl+enter"]
      assert Keybindings.get_keys(kb, "tui.select.confirm") == ["enter"]
    end

    test "shared-key sibling retains its default after an additive rebind" do
      kb = Keybindings.new(%{"tui.select.up" => ["up", "ctrl+p"]})
      assert Keybindings.get_keys(kb, "tui.select.up") == ["up", "ctrl+p"]
      assert Keybindings.get_keys(kb, "tui.editor.cursorUp") == ["up"]
    end

    test "defaults preserved even when user introduces a conflict" do
      kb =
        Keybindings.new(%{
          "tui.input.submit" => ["ctrl+x"],
          "tui.select.confirm" => ["ctrl+x"]
        })

      assert Keybindings.get_keys(kb, "tui.editor.cursorLeft") == ["left", "ctrl+b"]
    end
  end

  describe "app-level bindings (opi-0g4.7)" do
    setup do
      {:ok, kb: Keybindings.new()}
    end

    test "app.interrupt matches escape", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: :escape}, "app.interrupt")
    end

    test "app.clear matches ctrl+c", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?c, modifiers: [:ctrl]}, "app.clear")
    end

    test "app.exit matches ctrl+d", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?d, modifiers: [:ctrl]}, "app.exit")
    end

    test "app.suspend matches ctrl+z", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?z, modifiers: [:ctrl]}, "app.suspend")
    end

    test "app.thinking.cycle matches shift+tab", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: :tab, modifiers: [:shift]}, "app.thinking.cycle")
    end

    test "app.model.cycleForward matches ctrl+p", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?p, modifiers: [:ctrl]}, "app.model.cycleForward")
    end

    test "app.model.cycleBackward matches shift+ctrl+p", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?p, modifiers: [:shift, :ctrl]}, "app.model.cycleBackward")
    end

    test "app.model.select matches ctrl+l", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?l, modifiers: [:ctrl]}, "app.model.select")
    end

    test "app.tools.expand matches ctrl+o", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?o, modifiers: [:ctrl]}, "app.tools.expand")
    end

    test "app.thinking.toggle matches ctrl+t", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?t, modifiers: [:ctrl]}, "app.thinking.toggle")
    end

    test "app.editor.external matches ctrl+g", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?g, modifiers: [:ctrl]}, "app.editor.external")
    end

    test "app.message.followUp matches alt+enter", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: :enter, modifiers: [:alt]}, "app.message.followUp")
    end

    test "app.message.dequeue matches alt+up", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: :up, modifiers: [:alt]}, "app.message.dequeue")
    end

    test "app.clipboard.pasteImage matches ctrl+v", %{kb: kb} do
      assert Keybindings.matches?(kb, %Key{key: ?v, modifiers: [:ctrl]}, "app.clipboard.pasteImage")
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
