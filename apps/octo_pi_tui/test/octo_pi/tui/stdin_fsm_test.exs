defmodule OctoPi.TUI.StdinFSMTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.StdinFSM

  describe "printable chars" do
    test "single ASCII" do
      assert StdinFSM.decode("a") == {["a"], ""}
    end

    test "run of ASCII" do
      assert StdinFSM.decode("abc") == {["a", "b", "c"], ""}
    end

    test "UTF-8 codepoint (accented)" do
      assert StdinFSM.decode("é") == {["é"], ""}
    end

    test "UTF-8 codepoint (CJK)" do
      assert StdinFSM.decode("日本語") == {["日", "本", "語"], ""}
    end

    test "mixed ASCII + UTF-8" do
      assert StdinFSM.decode("aé日") == {["a", "é", "日"], ""}
    end

    test "unicode hello 世界" do
      assert StdinFSM.decode("hello 世界") ==
               {["h", "e", "l", "l", "o", " ", "世", "界"], ""}
    end
  end

  describe "complete escape sequences in one chunk" do
    test "CSI up arrow" do
      assert StdinFSM.decode("\e[A") == {["\e[A"], ""}
    end

    test "CSI F1 (\\e[11~)" do
      assert StdinFSM.decode("\e[11~") == {["\e[11~"], ""}
    end

    test "SS3 arrow (\\eOA)" do
      assert StdinFSM.decode("\eOA") == {["\eOA"], ""}
    end

    test "bracketed paste start marker" do
      assert StdinFSM.decode("\e[200~") == {["\e[200~"], ""}
    end

    test "meta key sequence (\\ea)" do
      assert StdinFSM.decode("\ea") == {["\ea"], ""}
    end

    test "multiple sequences in one chunk" do
      assert StdinFSM.decode("a\e[Ab") == {["a", "\e[A", "b"], ""}
    end
  end

  describe "incomplete sequences leave a tail" do
    test "bare ESC" do
      assert StdinFSM.decode("\e") == {[], "\e"}
    end

    test "ESC[ alone" do
      assert StdinFSM.decode("\e[") == {[], "\e["}
    end

    test "incomplete CSI after preceding chars" do
      assert StdinFSM.decode("abc\e[<35") == {["a", "b", "c"], "\e[<35"}
    end

    test "completed sequence followed by partial ESC" do
      assert StdinFSM.decode("\e[A\e") == {["\e[A"], "\e"}
    end

    test "incomplete DCS waits for ST" do
      assert StdinFSM.decode("\ePq#0") == {[], "\ePq#0"}
    end

    test "incomplete APC waits for ST" do
      assert StdinFSM.decode("\e_G;pay") == {[], "\e_G;pay"}
    end

    test "incomplete SS3 waits for the final byte" do
      assert StdinFSM.decode("\eO") == {[], "\eO"}
    end

    test "incomplete old-style mouse waits for 3 bytes" do
      assert StdinFSM.decode("\e[M a") == {[], "\e[M a"}
    end
  end

  describe "reassembly across chunks (caller threads the tail)" do
    test "ESC then [A" do
      {events, tail} = StdinFSM.decode("\e")
      assert {events, tail} == {[], "\e"}
      assert StdinFSM.decode(tail <> "[A") == {["\e[A"], ""}
    end

    test "many tiny chunks" do
      {events, tail} =
        Enum.reduce(String.graphemes("\e[11~"), {[], ""}, fn byte, {acc, tail} ->
          {events, tail} = StdinFSM.decode(tail <> byte)
          {acc ++ events, tail}
        end)

      assert events == ["\e[11~"]
      assert tail == ""
    end

    test "incomplete mouse SGR split across 3 chunks" do
      {events, tail} = StdinFSM.decode("\e")
      assert {events, tail} == {[], "\e"}

      {events, tail} = StdinFSM.decode(tail <> "[<35")
      assert {events, tail} == {[], "\e[<35"}

      {events, tail} = StdinFSM.decode(tail <> ";20;5m")
      assert {events, tail} == {["\e[<35;20;5m"], ""}
    end

    test "incomplete CSI reassembled from 3 chunks" do
      {e1, t1} = StdinFSM.decode("\e[")
      {e2, t2} = StdinFSM.decode(t1 <> "1;")
      {e3, t3} = StdinFSM.decode(t2 <> "5H")

      assert e1 == []
      assert e2 == []
      assert e3 == ["\e[1;5H"]
      assert t3 == ""
    end
  end

  describe "OSC sequences" do
    test "\\e]0;title\\x07 (BEL terminator)" do
      assert StdinFSM.decode("\e]0;hello\x07") == {["\e]0;hello\x07"], ""}
    end

    test "\\e]... \\e\\\\ (ST terminator)" do
      assert StdinFSM.decode("\e]0;x\e\\") == {["\e]0;x\e\\"], ""}
    end
  end

  describe "DCS sequences" do
    test "complete DCS with ST terminator is emitted as one sequence" do
      assert StdinFSM.decode("\ePq#0\e\\") == {["\ePq#0\e\\"], ""}
    end

    test "DCS split across chunks reassembles when ST arrives" do
      {events, tail} = StdinFSM.decode("\ePq")
      assert {events, tail} == {[], "\ePq"}
      assert StdinFSM.decode(tail <> "#0\e\\") == {["\ePq#0\e\\"], ""}
    end

    test "DCS does not emit spurious alt-prefix for ESC+P" do
      {events, _tail} = StdinFSM.decode("\ePdata\e\\")
      refute "\eP" in events
    end
  end

  describe "APC sequences" do
    test "complete APC with ST terminator is emitted as one sequence" do
      assert StdinFSM.decode("\e_G;payload\e\\") == {["\e_G;payload\e\\"], ""}
    end

    test "APC split across chunks reassembles when ST arrives" do
      {events, tail} = StdinFSM.decode("\e_G;")
      assert {events, tail} == {[], "\e_G;"}
      assert StdinFSM.decode(tail <> "payload\e\\") == {["\e_G;payload\e\\"], ""}
    end

    test "APC does not emit spurious alt-prefix for ESC+_" do
      {events, _tail} = StdinFSM.decode("\e_data\e\\")
      refute "\e_" in events
    end
  end

  describe "alt-prefix (ESC + char)" do
    test "ESC + letter emits immediately" do
      assert StdinFSM.decode("\eb") == {["\eb"], ""}
    end

    test "ESC + space" do
      assert StdinFSM.decode("\e ") == {["\e "], ""}
    end

    test "ESC + backspace" do
      assert StdinFSM.decode("\e\b") == {["\e\b"], ""}
    end

    test "ESC + Ctrl+C (ctrl+alt+c)" do
      assert StdinFSM.decode("\e\x03") == {["\e\x03"], ""}
    end

    test "ESC + ESC (ctrl+alt+[)" do
      assert StdinFSM.decode("\e\e") == {["\e\e"], ""}
    end

    test "alt+a followed by alt+z" do
      assert StdinFSM.decode("\ea\ez") == {["\ea", "\ez"], ""}
    end

    test "alt+1" do
      assert StdinFSM.decode("\e1") == {["\e1"], ""}
    end
  end

  describe "Kitty keyboard protocol" do
    test "Kitty CSI-u press event" do
      assert StdinFSM.decode("\e[97u") == {["\e[97u"], ""}
    end

    test "Kitty CSI-u release event" do
      assert StdinFSM.decode("\e[97;1:3u") == {["\e[97;1:3u"], ""}
    end

    test "batched Kitty press and release" do
      assert StdinFSM.decode("\e[97u\e[97;1:3u") == {["\e[97u", "\e[97;1:3u"], ""}
    end

    test "multiple batched Kitty events" do
      assert StdinFSM.decode("\e[97u\e[97;1:3u\e[98u\e[98;1:3u") ==
               {["\e[97u", "\e[97;1:3u", "\e[98u", "\e[98;1:3u"], ""}
    end

    test "Kitty arrow with event type" do
      assert StdinFSM.decode("\e[1;1:1A") == {["\e[1;1:1A"], ""}
    end

    test "Kitty functional key with event type" do
      assert StdinFSM.decode("\e[3;1:3~") == {["\e[3;1:3~"], ""}
    end

    test "plain char followed by Kitty release" do
      assert StdinFSM.decode("a\e[97;1:3u") == {["a", "\e[97;1:3u"], ""}
    end

    test "Kitty sequence followed by plain char" do
      assert StdinFSM.decode("\e[97ua") == {["\e[97u", "a"], ""}
    end
  end

  describe "mouse events" do
    test "SGR mouse press" do
      assert StdinFSM.decode("\e[<0;10;5M") == {["\e[<0;10;5M"], ""}
    end

    test "SGR mouse release" do
      assert StdinFSM.decode("\e[<0;10;5m") == {["\e[<0;10;5m"], ""}
    end

    test "SGR mouse move" do
      assert StdinFSM.decode("\e[<35;20;5m") == {["\e[<35;20;5m"], ""}
    end

    test "multiple SGR mouse events" do
      assert StdinFSM.decode("\e[<35;1;1m\e[<35;2;2m\e[<35;3;3m") ==
               {["\e[<35;1;1m", "\e[<35;2;2m", "\e[<35;3;3m"], ""}
    end

    test "old-style mouse (ESC[M + 3 bytes)" do
      assert StdinFSM.decode("\e[M abc") == {["\e[M ab", "c"], ""}
    end
  end

  describe "bracketed paste" do
    test "complete paste in one chunk emits markers + content as separate events" do
      {events, ""} = StdinFSM.decode("\e[200~hello world\e[201~")
      assert "\e[200~" in events
      assert "\e[201~" in events
    end

    test "paste with unicode content" do
      {events, ""} = StdinFSM.decode("\e[200~Hello 世界\e[201~")
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
      text = events |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join()
      assert text == "Hello 世界"
    end

    test "paste with newlines" do
      {events, ""} = StdinFSM.decode("\e[200~line1\nline2\e[201~")
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
    end
  end

  describe "edge cases" do
    test "very long CSI sequence" do
      long_seq = "\e[" <> String.duplicate("1;", 50) <> "H"
      assert StdinFSM.decode(long_seq) == {[long_seq], ""}
    end

    test "empty binary is a no-op" do
      assert StdinFSM.decode("") == {[], ""}
    end
  end
end
