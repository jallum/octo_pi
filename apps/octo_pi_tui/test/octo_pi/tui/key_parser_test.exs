defmodule OctoPi.TUI.KeyParserTest do
  # async: false — "Windows Terminal 0x08" tests mutate WT/SSH env vars.
  use ExUnit.Case, async: false

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.KeyParser

  @wt_env_keys ~w(WT_SESSION SSH_CONNECTION SSH_CLIENT SSH_TTY)

  defp with_wt_env(overrides, fun) do
    saved = Map.new(@wt_env_keys, fn k -> {k, System.get_env(k)} end)
    for k <- @wt_env_keys, do: System.delete_env(k)
    for {k, v} <- overrides, v != nil, do: System.put_env(k, v)

    try do
      fun.()
    after
      for k <- @wt_env_keys do
        case saved[k] do
          nil -> System.delete_env(k)
          v -> System.put_env(k, v)
        end
      end
    end
  end

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

    test "backspace (BS  0x08) outside Windows Terminal" do
      with_wt_env(%{}, fn ->
        assert {:key, %Key{key: :backspace, modifiers: []}} = KeyParser.parse("\b")
      end)
    end
  end

  describe "Windows Terminal 0x08 handling" do
    # Upstream keys.test.ts verifies three cases: default, local WT
    # (WT_SESSION set, no SSH), WT over SSH (WT_SESSION + SSH_*).

    test "raw 0x08 → plain backspace outside Windows Terminal" do
      with_wt_env(%{}, fn ->
        assert {:key, %Key{key: :backspace, modifiers: []}} = KeyParser.parse("\b")
      end)
    end

    test "raw 0x08 → ctrl+backspace in local Windows Terminal" do
      with_wt_env(%{"WT_SESSION" => "abc"}, fn ->
        assert {:key, %Key{key: :backspace, modifiers: [:ctrl]}} = KeyParser.parse("\b")
      end)
    end

    test "raw 0x08 → plain backspace in Windows Terminal over SSH" do
      for ssh_key <- ~w(SSH_CONNECTION SSH_CLIENT SSH_TTY) do
        with_wt_env(%{"WT_SESSION" => "abc", ssh_key => "..."}, fn ->
          assert {:key, %Key{key: :backspace, modifiers: []}} = KeyParser.parse("\b"),
                 "ssh var #{ssh_key} did not override WT mapping"
        end)
      end
    end
  end

  describe "Ctrl+letter (C0 controls)" do
    test "Ctrl+A" do
      assert {:key, %Key{key: ?a, modifiers: [:ctrl]}} = KeyParser.parse(<<0x01>>)
    end

    test "Ctrl+C" do
      assert {:key, %Key{key: ?c, modifiers: [:ctrl]}} = KeyParser.parse(<<0x03>>)
    end

    test "Ctrl+D" do
      assert {:key, %Key{key: ?d, modifiers: [:ctrl]}} = KeyParser.parse(<<0x04>>)
    end

    test "Ctrl+Z" do
      assert {:key, %Key{key: ?z, modifiers: [:ctrl]}} = KeyParser.parse(<<0x1A>>)
    end
  end

  describe "Ctrl+Space (NUL)" do
    test "0x00 → Ctrl+Space" do
      assert {:key, %Key{key: :space, modifiers: [:ctrl]}} = KeyParser.parse(<<0x00>>)
    end
  end

  describe "Ctrl+symbol" do
    test "Ctrl+\\ (0x1C)" do
      assert {:key, %Key{key: ?\\, modifiers: [:ctrl]}} = KeyParser.parse(<<0x1C>>)
    end

    test "Ctrl+] (0x1D)" do
      assert {:key, %Key{key: ?], modifiers: [:ctrl]}} = KeyParser.parse(<<0x1D>>)
    end

    test "Ctrl+- (0x1F)" do
      assert {:key, %Key{key: ?-, modifiers: [:ctrl]}} = KeyParser.parse(<<0x1F>>)
    end

    test "Ctrl+^ (0x1E)" do
      assert {:key, %Key{key: ?^, modifiers: [:ctrl]}} = KeyParser.parse(<<0x1E>>)
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

    test "clear (CSI E)", do: assert({:key, %Key{key: :clear}} = KeyParser.parse("\e[E"))

    test "F1 (CSI 11~)", do: assert({:key, %Key{key: :f1}} = KeyParser.parse("\e[11~"))
    test "F12 (CSI 24~)", do: assert({:key, %Key{key: :f12}} = KeyParser.parse("\e[24~"))

    test "double-bracket pageUp (\\e[[5~)" do
      assert {:key, %Key{key: :page_up}} = KeyParser.parse("\e[[5~")
    end
  end

  describe "SS3 sequences (application keypad)" do
    test "SS3 up", do: assert({:key, %Key{key: :up}} = KeyParser.parse("\eOA"))
    test "SS3 down", do: assert({:key, %Key{key: :down}} = KeyParser.parse("\eOB"))
    test "SS3 right", do: assert({:key, %Key{key: :right}} = KeyParser.parse("\eOC"))
    test "SS3 left", do: assert({:key, %Key{key: :left}} = KeyParser.parse("\eOD"))

    test "SS3 home", do: assert({:key, %Key{key: :home}} = KeyParser.parse("\eOH"))
    test "SS3 end", do: assert({:key, %Key{key: :end}} = KeyParser.parse("\eOF"))

    test "SS3 F1", do: assert({:key, %Key{key: :f1}} = KeyParser.parse("\eOP"))
    test "SS3 F2", do: assert({:key, %Key{key: :f2}} = KeyParser.parse("\eOQ"))
    test "SS3 F3", do: assert({:key, %Key{key: :f3}} = KeyParser.parse("\eOR"))
    test "SS3 F4", do: assert({:key, %Key{key: :f4}} = KeyParser.parse("\eOS"))
  end

  describe "rxvt modifier sequences" do
    test "shift+up (\\e[a)" do
      assert {:key, %Key{key: :up, modifiers: [:shift]}} = KeyParser.parse("\e[a")
    end

    test "shift+down (\\e[b)" do
      assert {:key, %Key{key: :down, modifiers: [:shift]}} = KeyParser.parse("\e[b")
    end

    test "shift+right (\\e[c)" do
      assert {:key, %Key{key: :right, modifiers: [:shift]}} = KeyParser.parse("\e[c")
    end

    test "shift+left (\\e[d)" do
      assert {:key, %Key{key: :left, modifiers: [:shift]}} = KeyParser.parse("\e[d")
    end

    test "ctrl+up via SS3 (\\eOa)" do
      assert {:key, %Key{key: :up, modifiers: [:ctrl]}} = KeyParser.parse("\eOa")
    end

    test "ctrl+down via SS3 (\\eOb)" do
      assert {:key, %Key{key: :down, modifiers: [:ctrl]}} = KeyParser.parse("\eOb")
    end

    test "shift+insert (\\e[2$)" do
      assert {:key, %Key{key: :insert, modifiers: [:shift]}} = KeyParser.parse("\e[2$")
    end

    test "ctrl+insert (\\e[2^)" do
      assert {:key, %Key{key: :insert, modifiers: [:ctrl]}} = KeyParser.parse("\e[2^")
    end

    test "shift+home (\\e[7$)" do
      assert {:key, %Key{key: :home, modifiers: [:shift]}} = KeyParser.parse("\e[7$")
    end

    test "ctrl+home (\\e[7^)" do
      assert {:key, %Key{key: :home, modifiers: [:ctrl]}} = KeyParser.parse("\e[7^")
    end
  end

  describe "alt-prefix legacy (ESC + byte)" do
    test "alt+a" do
      assert {:key, %Key{key: ?a, modifiers: [:alt]}} = KeyParser.parse("\ea")
    end

    test "alt+z" do
      assert {:key, %Key{key: ?z, modifiers: [:alt]}} = KeyParser.parse("\ez")
    end

    test "alt+y" do
      assert {:key, %Key{key: ?y, modifiers: [:alt]}} = KeyParser.parse("\ey")
    end

    test "alt+1" do
      assert {:key, %Key{key: ?1, modifiers: [:alt]}} = KeyParser.parse("\e1")
    end

    test "alt+space" do
      assert {:key, %Key{key: :space, modifiers: [:alt]}} = KeyParser.parse("\e ")
    end

    test "alt+backspace (BS)" do
      assert {:key, %Key{key: :backspace, modifiers: [:alt]}} = KeyParser.parse("\e\b")
    end

    test "alt+backspace (DEL)" do
      assert {:key, %Key{key: :backspace, modifiers: [:alt]}} = KeyParser.parse("\e\x7f")
    end

    test "alt+left (\\eB)" do
      assert {:key, %Key{key: :left, modifiers: [:alt]}} = KeyParser.parse("\eB")
    end

    test "alt+right (\\eF)" do
      assert {:key, %Key{key: :right, modifiers: [:alt]}} = KeyParser.parse("\eF")
    end

    test "alt+left (\\eb, readline)" do
      assert {:key, %Key{key: :left, modifiers: [:alt]}} = KeyParser.parse("\eb")
    end

    test "alt+right (\\ef, readline)" do
      assert {:key, %Key{key: :right, modifiers: [:alt]}} = KeyParser.parse("\ef")
    end

    test "alt+up (\\ep, rxvt)" do
      assert {:key, %Key{key: :up, modifiers: [:alt]}} = KeyParser.parse("\ep")
    end

    test "alt+down (\\eq, rxvt)" do
      assert {:key, %Key{key: :down, modifiers: [:alt]}} = KeyParser.parse("\eq")
    end

    test "alt+enter (ESC + CR, legacy)" do
      assert {:key, %Key{key: :enter, modifiers: [:alt]}} = KeyParser.parse("\e\r")
    end

    test "ctrl+alt+c" do
      assert {:key, %Key{key: ?c, modifiers: [:alt, :ctrl]}} = KeyParser.parse("\e\x03")
    end

    test "ctrl+alt+[ (ESC ESC)" do
      assert {:key, %Key{key: ?[, modifiers: [:alt, :ctrl]}} = KeyParser.parse("\e\e")
    end

    test "ctrl+alt+\\ (ESC 0x1C)" do
      assert {:key, %Key{key: ?\\, modifiers: [:alt, :ctrl]}} = KeyParser.parse("\e\x1c")
    end

    test "ctrl+alt+] (ESC 0x1D)" do
      assert {:key, %Key{key: ?], modifiers: [:alt, :ctrl]}} = KeyParser.parse("\e\x1d")
    end

    test "ctrl+alt+- (ESC 0x1F)" do
      assert {:key, %Key{key: ?-, modifiers: [:alt, :ctrl]}} = KeyParser.parse("\e\x1f")
    end
  end

  describe "xterm modifyOtherKeys (\\e[27;<mod>;<cp>~)" do
    test "ctrl+c" do
      assert {:key, %Key{key: ?c, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;99~")
    end

    test "ctrl+d" do
      assert {:key, %Key{key: ?d, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;100~")
    end

    test "ctrl+z" do
      assert {:key, %Key{key: ?z, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;122~")
    end

    test "ctrl+enter" do
      assert {:key, %Key{key: :enter, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;13~")
    end

    test "shift+enter" do
      assert {:key, %Key{key: :enter, modifiers: [:shift]}} = KeyParser.parse("\e[27;2;13~")
    end

    test "alt+enter" do
      assert {:key, %Key{key: :enter, modifiers: [:alt]}} = KeyParser.parse("\e[27;3;13~")
    end

    test "shift+tab" do
      assert {:key, %Key{key: :tab, modifiers: [:shift]}} = KeyParser.parse("\e[27;2;9~")
    end

    test "ctrl+tab" do
      assert {:key, %Key{key: :tab, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;9~")
    end

    test "backspace (no modifier)" do
      assert {:key, %Key{key: :backspace, modifiers: []}} = KeyParser.parse("\e[27;1;127~")
    end

    test "ctrl+backspace" do
      assert {:key, %Key{key: :backspace, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;127~")
    end

    test "alt+backspace" do
      assert {:key, %Key{key: :backspace, modifiers: [:alt]}} = KeyParser.parse("\e[27;3;127~")
    end

    test "escape (no modifier)" do
      assert {:key, %Key{key: :escape, modifiers: []}} = KeyParser.parse("\e[27;1;27~")
    end

    test "space (no modifier)" do
      assert {:key, %Key{key: :space, modifiers: []}} = KeyParser.parse("\e[27;1;32~")
    end

    test "ctrl+space" do
      assert {:key, %Key{key: :space, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;32~")
    end

    test "ctrl+/" do
      assert {:key, %Key{key: ?/, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;47~")
    end

    test "ctrl+1" do
      assert {:key, %Key{key: ?1, modifiers: [:ctrl]}} = KeyParser.parse("\e[27;5;49~")
    end

    test "shift+1" do
      assert {:key, %Key{key: ?1, modifiers: [:shift]}} = KeyParser.parse("\e[27;2;49~")
    end

    test "shift+e (uppercase E normalized)" do
      assert {:key, %Key{key: ?e, modifiers: [:shift]}} = KeyParser.parse("\e[27;2;69~")
    end

    test "ctrl+shift+e" do
      result = KeyParser.parse("\e[27;6;69~")
      assert {:key, %Key{key: ?e}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :shift]
    end

    test "ctrl+alt+h" do
      result = KeyParser.parse("\e[27;7;104~")
      assert {:key, %Key{key: ?h}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:alt, :ctrl]
    end
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
      mods = "\e[97;6u" |> KeyParser.parse() |> elem(1) |> Map.fetch!(:modifiers) |> Enum.sort()
      assert mods == [:ctrl, :shift]
    end

    test "with event_type repeat: \\e[97;1:2u" do
      assert {:key, %Key{key: ?a, modifiers: [], event_type: :repeat}} =
               KeyParser.parse("\e[97;1:2u")
    end

    test "with event_type release: \\e[97;1:3u" do
      assert {:key, %Key{event_type: :release}} = KeyParser.parse("\e[97;1:3u")
    end

    test "digit via CSI-u" do
      assert {:key, %Key{key: ?1, modifiers: [], event_type: :press}} =
               KeyParser.parse("\e[49u")
    end

    test "ctrl+1 via CSI-u" do
      assert {:key, %Key{key: ?1, modifiers: [:ctrl]}} = KeyParser.parse("\e[49;5u")
    end

    test "shift+e (uppercase 69 via CSI-u)" do
      assert {:key, %Key{key: ?E, modifiers: [:shift]}} = KeyParser.parse("\e[69;2u")
    end
  end

  describe "Kitty CSI-u — super modifier" do
    test "super+k" do
      assert {:key, %Key{key: ?k, modifiers: [:super]}} = KeyParser.parse("\e[107;9u")
    end

    test "super+enter" do
      assert {:key, %Key{key: :enter, modifiers: [:super]}} = KeyParser.parse("\e[13;9u")
    end

    test "ctrl+super+k" do
      result = KeyParser.parse("\e[107;13u")
      assert {:key, %Key{key: ?k}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :super]
    end

    test "ctrl+shift+super+k" do
      result = KeyParser.parse("\e[107;14u")
      assert {:key, %Key{key: ?k}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :shift, :super]
    end
  end

  describe "Kitty CSI-u — alternate layouts (Cyrillic/Dvorak)" do
    test "Cyrillic Ctrl+С with base 'c'" do
      # Cyrillic 'с' = 1089, base 'c' = 99, ctrl = mod 5
      assert {:key, %Key{key: ?c, modifiers: [:ctrl]}} =
               KeyParser.parse("\e[1089::99;5u")
    end

    test "Cyrillic Ctrl+В with base 'd'" do
      assert {:key, %Key{key: ?d, modifiers: [:ctrl]}} =
               KeyParser.parse("\e[1074::100;5u")
    end

    test "Cyrillic Ctrl+Я with base 'z'" do
      assert {:key, %Key{key: ?z, modifiers: [:ctrl]}} =
               KeyParser.parse("\e[1103::122;5u")
    end

    test "Cyrillic Ctrl+Shift+P with base 'p'" do
      result = KeyParser.parse("\e[1079::112;6u")
      assert {:key, %Key{key: ?p}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :shift]
    end

    test "Latin Ctrl+C without base (terminal doesn't report it)" do
      assert {:key, %Key{key: ?c, modifiers: [:ctrl]}} = KeyParser.parse("\e[99;5u")
    end

    test "Dvorak Ctrl+K: prefer codepoint over base" do
      # codepoint 'k' (107), base 'v' (118) → ctrl+k
      assert {:key, %Key{key: ?k, modifiers: [:ctrl]}} =
               KeyParser.parse("\e[107::118;5u")
    end

    test "Dvorak Ctrl+/: prefer codepoint over base" do
      # codepoint '/' (47), base '[' (91) → ctrl+/
      assert {:key, %Key{key: ?/, modifiers: [:ctrl]}} =
               KeyParser.parse("\e[47::91;5u")
    end

    test "shifted key in format" do
      # cp=99 (c), shifted=67 (C), base=99 (c), shift mod
      assert {:key, %Key{key: ?c, modifiers: [:shift]}} =
               KeyParser.parse("\e[99:67:99;2u")
    end

    test "event type in full format" do
      # Cyrillic ctrl+c release: cp=1089, base=99, mod=5, event=3
      assert {:key, %Key{key: ?c, modifiers: [:ctrl], event_type: :release}} =
               KeyParser.parse("\e[1089::99;5:3u")
    end

    test "full format: cp:shifted:base;mod:event" do
      # cp=1089, shifted=1057, base=99, mod=6 (ctrl+shift), event=2 (repeat)
      result = KeyParser.parse("\e[1089:1057:99;6:2u")
      assert {:key, %Key{key: ?c, event_type: :repeat}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :shift]
    end
  end

  describe "Kitty CSI-u — keypad functional keys" do
    test "keypad 0 (57399)" do
      assert {:char, "0"} = KeyParser.parse("\e[57399u")
    end

    test "keypad 1 (57400)" do
      assert {:char, "1"} = KeyParser.parse("\e[57400u")
    end

    test "keypad . (57409)" do
      assert {:char, "."} = KeyParser.parse("\e[57409u")
    end

    test "keypad / (57410)" do
      assert {:char, "/"} = KeyParser.parse("\e[57410u")
    end

    test "keypad + (57413)" do
      assert {:char, "+"} = KeyParser.parse("\e[57413u")
    end

    test "keypad , (57416)" do
      assert {:char, ","} = KeyParser.parse("\e[57416u")
    end

    test "keypad left (57417)" do
      assert {:key, %Key{key: :left}} = KeyParser.parse("\e[57417u")
    end

    test "keypad right (57418)" do
      assert {:key, %Key{key: :right}} = KeyParser.parse("\e[57418u")
    end

    test "keypad up (57419)" do
      assert {:key, %Key{key: :up}} = KeyParser.parse("\e[57419u")
    end

    test "keypad down (57420)" do
      assert {:key, %Key{key: :down}} = KeyParser.parse("\e[57420u")
    end

    test "keypad page_up (57421)" do
      assert {:key, %Key{key: :page_up}} = KeyParser.parse("\e[57421u")
    end

    test "keypad page_down (57422)" do
      assert {:key, %Key{key: :page_down}} = KeyParser.parse("\e[57422u")
    end

    test "keypad home (57423)" do
      assert {:key, %Key{key: :home}} = KeyParser.parse("\e[57423u")
    end

    test "keypad end (57424)" do
      assert {:key, %Key{key: :end}} = KeyParser.parse("\e[57424u")
    end

    test "keypad insert (57425)" do
      assert {:key, %Key{key: :insert}} = KeyParser.parse("\e[57425u")
    end

    test "keypad delete (57426)" do
      assert {:key, %Key{key: :delete}} = KeyParser.parse("\e[57426u")
    end
  end

  describe "Kitty CSI-u — named special keys" do
    test "enter via CSI-u" do
      assert {:key, %Key{key: :enter, modifiers: []}} = KeyParser.parse("\e[13u")
    end

    test "super+enter via CSI-u" do
      assert {:key, %Key{key: :enter, modifiers: [:super]}} = KeyParser.parse("\e[13;9u")
    end

    test "tab via CSI-u" do
      assert {:key, %Key{key: :tab, modifiers: []}} = KeyParser.parse("\e[9u")
    end

    test "escape via CSI-u" do
      assert {:key, %Key{key: :escape, modifiers: []}} = KeyParser.parse("\e[27u")
    end

    test "backspace via CSI-u" do
      assert {:key, %Key{key: :backspace, modifiers: []}} = KeyParser.parse("\e[127u")
    end
  end

  describe "xterm modified CSI — arrows (opi-0g4.5)" do
    test "shift+up (\\e[1;2A)" do
      assert {:key, %Key{key: :up, modifiers: [:shift]}} = KeyParser.parse("\e[1;2A")
    end

    test "ctrl+up (\\e[1;5A)" do
      assert {:key, %Key{key: :up, modifiers: [:ctrl]}} = KeyParser.parse("\e[1;5A")
    end

    test "alt+up (\\e[1;3A)" do
      assert {:key, %Key{key: :up, modifiers: [:alt]}} = KeyParser.parse("\e[1;3A")
    end

    test "shift+down (\\e[1;2B)" do
      assert {:key, %Key{key: :down, modifiers: [:shift]}} = KeyParser.parse("\e[1;2B")
    end

    test "shift+right (\\e[1;2C)" do
      assert {:key, %Key{key: :right, modifiers: [:shift]}} = KeyParser.parse("\e[1;2C")
    end

    test "shift+left (\\e[1;2D)" do
      assert {:key, %Key{key: :left, modifiers: [:shift]}} = KeyParser.parse("\e[1;2D")
    end

    test "ctrl+shift+up (\\e[1;6A)" do
      result = KeyParser.parse("\e[1;6A")
      assert {:key, %Key{key: :up}} = result
      assert result |> elem(1) |> Map.get(:modifiers) |> Enum.sort() == [:ctrl, :shift]
    end
  end

  describe "xterm modified CSI — home/end (opi-0g4.5)" do
    test "shift+home (\\e[1;2H)" do
      assert {:key, %Key{key: :home, modifiers: [:shift]}} = KeyParser.parse("\e[1;2H")
    end

    test "ctrl+home (\\e[1;5H)" do
      assert {:key, %Key{key: :home, modifiers: [:ctrl]}} = KeyParser.parse("\e[1;5H")
    end

    test "shift+end (\\e[1;2F)" do
      assert {:key, %Key{key: :end, modifiers: [:shift]}} = KeyParser.parse("\e[1;2F")
    end

    test "ctrl+end (\\e[1;5F)" do
      assert {:key, %Key{key: :end, modifiers: [:ctrl]}} = KeyParser.parse("\e[1;5F")
    end
  end

  describe "xterm modified CSI — F1-F4 via 1;<mod> (opi-0g4.5)" do
    test "shift+F1 (\\e[1;2P)" do
      assert {:key, %Key{key: :f1, modifiers: [:shift]}} = KeyParser.parse("\e[1;2P")
    end

    test "ctrl+F2 (\\e[1;5Q)" do
      assert {:key, %Key{key: :f2, modifiers: [:ctrl]}} = KeyParser.parse("\e[1;5Q")
    end

    test "alt+F3 (\\e[1;3R)" do
      assert {:key, %Key{key: :f3, modifiers: [:alt]}} = KeyParser.parse("\e[1;3R")
    end

    test "shift+F4 (\\e[1;2S)" do
      assert {:key, %Key{key: :f4, modifiers: [:shift]}} = KeyParser.parse("\e[1;2S")
    end
  end

  describe "xterm modified CSI — nav/F-keys via <n>;<mod>~ (opi-0g4.5)" do
    test "shift+insert (\\e[2;2~)" do
      assert {:key, %Key{key: :insert, modifiers: [:shift]}} = KeyParser.parse("\e[2;2~")
    end

    test "ctrl+delete (\\e[3;5~)" do
      assert {:key, %Key{key: :delete, modifiers: [:ctrl]}} = KeyParser.parse("\e[3;5~")
    end

    test "ctrl+page_up (\\e[5;5~)" do
      assert {:key, %Key{key: :page_up, modifiers: [:ctrl]}} = KeyParser.parse("\e[5;5~")
    end

    test "shift+page_down (\\e[6;2~)" do
      assert {:key, %Key{key: :page_down, modifiers: [:shift]}} = KeyParser.parse("\e[6;2~")
    end

    test "shift+F1 via tilde (\\e[11;2~)" do
      assert {:key, %Key{key: :f1, modifiers: [:shift]}} = KeyParser.parse("\e[11;2~")
    end

    test "ctrl+F5 (\\e[15;5~)" do
      assert {:key, %Key{key: :f5, modifiers: [:ctrl]}} = KeyParser.parse("\e[15;5~")
    end

    test "alt+F12 (\\e[24;3~)" do
      assert {:key, %Key{key: :f12, modifiers: [:alt]}} = KeyParser.parse("\e[24;3~")
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
