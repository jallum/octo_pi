defmodule OctoPi.TUI.KeyTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Key

  describe "matches?/2 — printable + modifier combinations" do
    test "ctrl+letter" do
      assert Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "ctrl+c")
      refute Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "ctrl+d")
      refute Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "ctrl+shift+c")
    end

    test "ctrl+shift+letter — modifier order in binding does not matter" do
      assert Key.matches?(%Key{key: ?p, modifiers: [:ctrl, :shift]}, "ctrl+shift+p")
      assert Key.matches?(%Key{key: ?p, modifiers: [:ctrl, :shift]}, "shift+ctrl+p")
    end

    test "alt+letter / super+letter" do
      assert Key.matches?(%Key{key: ?b, modifiers: [:alt]}, "alt+b")
      assert Key.matches?(%Key{key: ?p, modifiers: [:super]}, "super+p")
    end

    test "digits + symbols" do
      assert Key.matches?(%Key{key: ?1, modifiers: [:ctrl]}, "ctrl+1")
      assert Key.matches?(%Key{key: ?\\, modifiers: [:ctrl]}, "ctrl+\\")
      assert Key.matches?(%Key{key: ?], modifiers: [:ctrl]}, "ctrl+]")
    end

    test "binding case-insensitive" do
      assert Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "CTRL+c")
      assert Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "Ctrl+C")
    end
  end

  describe "matches?/2 — named keys" do
    test "plain enter / escape / tab" do
      assert Key.matches?(%Key{key: :enter}, "enter")
      assert Key.matches?(%Key{key: :escape}, "escape")
      assert Key.matches?(%Key{key: :tab}, "tab")
      refute Key.matches?(%Key{key: :enter}, "escape")
    end

    test "modified named keys" do
      assert Key.matches?(%Key{key: :enter, modifiers: [:shift]}, "shift+enter")
      assert Key.matches?(%Key{key: :tab, modifiers: [:ctrl]}, "ctrl+tab")
      assert Key.matches?(%Key{key: :backspace, modifiers: [:alt]}, "alt+backspace")
    end

    test "pageUp / pageDown case-insensitive binding" do
      assert Key.matches?(%Key{key: :pageUp}, "pageUp")
      assert Key.matches?(%Key{key: :pageUp}, "pageup")
      assert Key.matches?(%Key{key: :pageDown}, "pagedown")
    end

    test "named-key binding does not match codepoint-keyed key" do
      refute Key.matches?(%Key{key: ?e}, "enter")
    end
  end

  describe "matches?/2 — codepoint preference (layout already resolved)" do
    test "parser resolves Cyrillic Ctrl+С to ctrl+c-compatible key" do
      # After KeyParser.resolve_key_with_base, a Cyrillic С pressed
      # with Ctrl in Kitty protocol surfaces as %Key{key: ?c, ...}.
      # matches?/2 does not re-resolve — it trusts the parsed Key.
      key = %Key{key: ?c, modifiers: [:ctrl]}
      assert Key.matches?(key, "ctrl+c")
    end

    test "does not match wrong codepoint even with correct modifiers" do
      refute Key.matches?(%Key{key: ?a, modifiers: [:ctrl]}, "ctrl+c")
    end

    test "does not match wrong modifiers even with correct codepoint" do
      refute Key.matches?(%Key{key: ?c, modifiers: [:ctrl]}, "alt+c")
      refute Key.matches?(%Key{key: ?c, modifiers: []}, "ctrl+c")
    end
  end
end
