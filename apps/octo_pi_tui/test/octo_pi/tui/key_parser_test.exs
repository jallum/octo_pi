defmodule OctoPi.TUI.KeyParserTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.{Key, KeyParser}

  describe "printable chars" do
    test "ASCII letter", do: assert({:char, "a"} = KeyParser.parse("a"))
    test "ASCII digit", do: assert({:char, "5"} = KeyParser.parse("5"))
    test "ASCII symbol", do: assert({:char, "!"} = KeyParser.parse("!"))
    test "space", do: assert({:char, " "} = KeyParser.parse(" "))

    test "non-ASCII Unicode (accented)", do: assert({:char, "é"} = KeyParser.parse("é"))
    test "non-ASCII Unicode (CJK)", do: assert({:char, "日"} = KeyParser.parse("日"))
  end

  describe "named special keys" do
    test "enter (CR)", do: assert({:key, %Key{key: :enter}} = KeyParser.parse("\r"))
    test "enter (LF)", do: assert({:key, %Key{key: :enter}} = KeyParser.parse("\n"))
    test "tab", do: assert({:key, %Key{key: :tab}} = KeyParser.parse("\t"))
    test "escape", do: assert({:key, %Key{key: :escape}} = KeyParser.parse("\e"))

    test "backspace (DEL 0x7f)",
      do: assert({:key, %Key{key: :backspace}} = KeyParser.parse("\x7f"))

    test "backspace (BS  0x08)", do: assert({:key, %Key{key: :backspace}} = KeyParser.parse("\b"))
  end

  describe "Ctrl+letter (C0 controls)" do
    test "Ctrl+A" do
      assert {:key, %Key{key: ?a, modifiers: [:ctrl]}} = KeyParser.parse(<<0x01>>)
    end

    test "Ctrl+C" do
      assert {:key, %Key{key: ?c, modifiers: [:ctrl]}} = KeyParser.parse(<<0x03>>)
    end

    test "Ctrl+Z" do
      assert {:key, %Key{key: ?z, modifiers: [:ctrl]}} = KeyParser.parse(<<0x1A>>)
    end
  end

  describe "legacy CSI sequences" do
    test "up arrow", do: assert({:key, %Key{key: :up}} = KeyParser.parse("\e[A"))
    test "down arrow", do: assert({:key, %Key{key: :down}} = KeyParser.parse("\e[B"))
    test "right arrow", do: assert({:key, %Key{key: :right}} = KeyParser.parse("\e[C"))
    test "left arrow", do: assert({:key, %Key{key: :left}} = KeyParser.parse("\e[D"))

    test "home (CSI H)", do: assert({:key, %Key{key: :home}} = KeyParser.parse("\e[H"))
    test "end (CSI F)", do: assert({:key, %Key{key: :end}} = KeyParser.parse("\e[F"))
    test "insert (CSI 2~)", do: assert({:key, %Key{key: :insert}} = KeyParser.parse("\e[2~"))
    test "delete (CSI 3~)", do: assert({:key, %Key{key: :delete}} = KeyParser.parse("\e[3~"))
    test "page_up (CSI 5~)", do: assert({:key, %Key{key: :page_up}} = KeyParser.parse("\e[5~"))

    test "page_down (CSI 6~)",
      do: assert({:key, %Key{key: :page_down}} = KeyParser.parse("\e[6~"))

    test "F1 (CSI 11~)", do: assert({:key, %Key{key: :f1}} = KeyParser.parse("\e[11~"))
    test "F12 (CSI 24~)", do: assert({:key, %Key{key: :f12}} = KeyParser.parse("\e[24~"))
  end

  describe "SS3 sequences (application keypad)" do
    test "SS3 up", do: assert({:key, %Key{key: :up}} = KeyParser.parse("\eOA"))
    test "SS3 down", do: assert({:key, %Key{key: :down}} = KeyParser.parse("\eOB"))
    test "SS3 right", do: assert({:key, %Key{key: :right}} = KeyParser.parse("\eOC"))
    test "SS3 left", do: assert({:key, %Key{key: :left}} = KeyParser.parse("\eOD"))
  end

  describe "Kitty CSI-u" do
    test "simple: \\e[97u → key :a" do
      assert {:key, %Key{key: ?a, modifiers: [], event_type: :press}} =
               KeyParser.parse("\e[97u")
    end

    test "with Ctrl modifier: \\e[97;5u (mod bitmask ctrl=4 → stored 5)" do
      assert {:key, %Key{key: ?a, modifiers: [:ctrl]}} = KeyParser.parse("\e[97;5u")
    end

    test "with Shift: \\e[97;2u" do
      assert {:key, %Key{key: ?a, modifiers: [:shift]}} = KeyParser.parse("\e[97;2u")
    end

    test "with Alt: \\e[97;3u" do
      assert {:key, %Key{key: ?a, modifiers: [:alt]}} = KeyParser.parse("\e[97;3u")
    end

    test "with Ctrl+Shift: \\e[97;6u" do
      mods = KeyParser.parse("\e[97;6u") |> elem(1) |> Map.fetch!(:modifiers) |> Enum.sort()
      assert mods == [:ctrl, :shift]
    end

    test "with event_type repeat: \\e[97;1:2u" do
      assert {:key, %Key{key: ?a, modifiers: [], event_type: :repeat}} =
               KeyParser.parse("\e[97;1:2u")
    end

    test "with event_type release: \\e[97;1:3u" do
      assert {:key, %Key{event_type: :release}} = KeyParser.parse("\e[97;1:3u")
    end
  end

  describe "bracketed paste markers" do
    test "paste start", do: assert(:paste_start = KeyParser.parse("\e[200~"))
    test "paste end", do: assert(:paste_end = KeyParser.parse("\e[201~"))
  end

  describe "unknown sequences" do
    test "bare ESC followed by unknown CSI" do
      assert :unknown = KeyParser.parse("\e[999Z")
    end

    test "random bytes" do
      assert :unknown = KeyParser.parse(<<0xFE, 0xFF>>)
    end

    test "empty string" do
      assert :unknown = KeyParser.parse("")
    end
  end

  describe "Key.id/1" do
    test "no modifiers → atom name" do
      assert "up" = Key.id(%Key{key: :up})
    end

    test "with modifier → mods+key" do
      assert "ctrl+97" = Key.id(%Key{key: ?a, modifiers: [:ctrl]})
    end

    test "multi-modifier sorted alphabetically" do
      assert "alt+ctrl+shift+97" =
               Key.id(%Key{key: ?a, modifiers: [:shift, :alt, :ctrl]})
    end
  end
end
