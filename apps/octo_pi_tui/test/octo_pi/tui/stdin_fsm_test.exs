defmodule OctoPi.TUI.StdinFSMTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.StdinFSM

  setup do
    {:ok, fsm: StdinFSM.new(flush_ms: 20)}
  end

  defp feed(fsm, bin) do
    {fsm, events, timeout} = StdinFSM.process(fsm, bin)
    {fsm, events, timeout}
  end

  describe "printable chars" do
    test "single ASCII", %{fsm: fsm} do
      {_fsm, events, timeout} = feed(fsm, "a")
      assert events == ["a"]
      assert timeout == :infinity
    end

    test "run of ASCII", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "abc")
      assert events == ["a", "b", "c"]
    end

    test "UTF-8 codepoint (accented)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "é")
      assert events == ["é"]
    end

    test "UTF-8 codepoint (CJK)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "日本語")
      assert events == ["日", "本", "語"]
    end

    test "mixed ASCII + UTF-8", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "aé日")
      assert events == ["a", "é", "日"]
    end

    test "unicode hello 世界", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "hello 世界")
      assert events == ["h", "e", "l", "l", "o", " ", "世", "界"]
    end
  end

  describe "complete escape sequences in one chunk" do
    test "CSI up arrow", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[A")
      assert events == ["\e[A"]
    end

    test "CSI F1 (\\e[11~)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[11~")
      assert events == ["\e[11~"]
    end

    test "SS3 arrow (\\eOA)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\eOA")
      assert events == ["\eOA"]
    end

    test "bracketed paste start marker", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[200~")
      assert events == ["\e[200~"]
    end

    test "meta key sequence (\\ea)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\ea")
      assert events == ["\ea"]
    end

    test "multiple sequences in one chunk", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "a\e[Ab")
      assert events == ["a", "\e[A", "b"]
    end
  end

  describe "sequences split across chunks" do
    test "ESC then [A", %{fsm: fsm} do
      {fsm, events, t1} = feed(fsm, "\e")
      assert events == []
      assert t1 == 20
      {_fsm, events, t2} = feed(fsm, "[A")
      assert events == ["\e[A"]
      assert t2 == :infinity
    end

    test "ESC[ then A", %{fsm: fsm} do
      {fsm, events, _t} = feed(fsm, "\e[")
      assert events == []
      {_fsm, events, _t} = feed(fsm, "A")
      assert events == ["\e[A"]
    end

    test "many tiny chunks", %{fsm: fsm} do
      {fsm, all} =
        Enum.reduce(String.graphemes("\e[11~"), {fsm, []}, fn byte, {fsm, acc} ->
          {fsm, events, _t} = feed(fsm, byte)
          {fsm, acc ++ events}
        end)

      assert all == ["\e[11~"]
      assert fsm.buffer == ""
    end

    test "chunks with text before and after the sequence", %{fsm: fsm} do
      {fsm, e1, _} = feed(fsm, "hi\e")
      {fsm, e2, _} = feed(fsm, "[A")
      {_fsm, e3, _} = feed(fsm, "there")
      assert e1 ++ e2 ++ e3 == ["h", "i", "\e[A", "t", "h", "e", "r", "e"]
    end

    test "incomplete mouse SGR split across 3 chunks", %{fsm: fsm} do
      {fsm, events, _t} = feed(fsm, "\e")
      assert events == []
      assert fsm.buffer == "\e"

      {fsm, events, _t} = feed(fsm, "[<35")
      assert events == []
      assert fsm.buffer == "\e[<35"

      {fsm, events, _t} = feed(fsm, ";20;5m")
      assert events == ["\e[<35;20;5m"]
      assert fsm.buffer == ""
    end

    test "incomplete CSI reassembled from 3 chunks", %{fsm: fsm} do
      {fsm, e1, _} = feed(fsm, "\e[")
      {fsm, e2, _} = feed(fsm, "1;")
      {_fsm, e3, _} = feed(fsm, "5H")
      assert e1 == []
      assert e2 == []
      assert e3 == ["\e[1;5H"]
    end

    test "split across many tiny chunks (SGR mouse)", %{fsm: fsm} do
      {_fsm, all} =
        Enum.reduce(["\e", "[", "<", "3", "5", ";", "2", "0", ";", "5", "m"], {fsm, []}, fn byte, {fsm, acc} ->
          {fsm, events, _t} = feed(fsm, byte)
          {fsm, acc ++ events}
        end)

      assert all == ["\e[<35;20;5m"]
    end
  end

  describe "flush timeout signaling" do
    test "bare ESC returns flush_ms timeout", %{fsm: fsm} do
      {fsm, events, timeout} = feed(fsm, "\e")
      assert events == []
      assert timeout == 20
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == ["\e"]
    end

    test "partial CSI returns flush_ms timeout, flush emits as-is", %{fsm: fsm} do
      {fsm, events, timeout} = feed(fsm, "\e[")
      assert events == []
      assert timeout == 20
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == ["\e["]
    end

    test "completed sequence followed by partial ESC: events + flush yields tail", %{fsm: fsm} do
      {fsm, events, timeout} = feed(fsm, "\e[A\e")
      assert events == ["\e[A"]
      assert timeout == 20
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == ["\e"]
    end

    test "incomplete partial sequence flushes intact after timeout", %{fsm: fsm} do
      {fsm, events, timeout} = feed(fsm, "\e[<35")
      assert events == []
      assert timeout == 20
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == ["\e[<35"]
    end
  end

  describe "mixed content" do
    test "chars followed by escape sequence", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "abc\e[A")
      assert events == ["a", "b", "c", "\e[A"]
    end

    test "escape sequence followed by chars", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[Aabc")
      assert events == ["\e[A", "a", "b", "c"]
    end

    test "multiple complete sequences", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[A\e[B\e[C")
      assert events == ["\e[A", "\e[B", "\e[C"]
    end

    test "partial sequence with preceding chars", %{fsm: fsm} do
      {fsm, events, _t} = feed(fsm, "abc\e[<35")
      assert events == ["a", "b", "c"]
      assert fsm.buffer == "\e[<35"

      {_fsm, events, _t} = feed(fsm, ";20;5m")
      assert events == ["\e[<35;20;5m"]
    end
  end

  describe "OSC sequences" do
    test "\\e]0;title\\x07 (BEL terminator)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e]0;hello\x07")
      assert events == ["\e]0;hello\x07"]
    end

    test "\\e]... \\e\\\\ (ST terminator)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e]0;x\e\\")
      assert events == ["\e]0;x\e\\"]
    end
  end

  describe "DCS sequences" do
    test "complete DCS with ST terminator is emitted as one sequence", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\ePq#0\e\\")
      assert events == ["\ePq#0\e\\"]
    end

    test "incomplete DCS waits for more data", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\ePq#0")
      assert events == []
    end

    test "DCS split across chunks buffers until ST arrives", %{fsm: fsm} do
      {fsm, events, _t} = feed(fsm, "\ePq")
      assert events == []
      {_fsm, events, _t} = feed(fsm, "#0\e\\")
      assert events == ["\ePq#0\e\\"]
    end

    test "DCS does not emit spurious alt-prefix for ESC+P", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\ePdata\e\\")
      refute "\eP" in events
    end
  end

  describe "APC sequences" do
    test "complete APC with ST terminator is emitted as one sequence", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e_G;payload\e\\")
      assert events == ["\e_G;payload\e\\"]
    end

    test "incomplete APC waits for more data", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e_G;pay")
      assert events == []
    end

    test "APC split across chunks buffers until ST arrives", %{fsm: fsm} do
      {fsm, events, _t} = feed(fsm, "\e_G;")
      assert events == []
      {_fsm, events, _t} = feed(fsm, "payload\e\\")
      assert events == ["\e_G;payload\e\\"]
    end

    test "APC does not emit spurious alt-prefix for ESC+_", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e_data\e\\")
      refute "\e_" in events
    end
  end

  describe "alt-prefix (ESC + char)" do
    test "ESC + letter emits immediately", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\eb")
      assert events == ["\eb"]
    end

    test "ESC + space", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e ")
      assert events == ["\e "]
    end

    test "ESC + backspace", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e\b")
      assert events == ["\e\b"]
    end

    test "ESC + Ctrl+C (ctrl+alt+c)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e\x03")
      assert events == ["\e\x03"]
    end

    test "ESC + ESC (ctrl+alt+[)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e\e")
      assert events == ["\e\e"]
    end

    test "alt+a followed by alt+z", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\ea\ez")
      assert events == ["\ea", "\ez"]
    end

    test "alt+1", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e1")
      assert events == ["\e1"]
    end
  end

  describe "Kitty keyboard protocol" do
    test "Kitty CSI-u press event", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[97u")
      assert events == ["\e[97u"]
    end

    test "Kitty CSI-u release event", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[97;1:3u")
      assert events == ["\e[97;1:3u"]
    end

    test "batched Kitty press and release", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[97u\e[97;1:3u")
      assert events == ["\e[97u", "\e[97;1:3u"]
    end

    test "multiple batched Kitty events", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[97u\e[97;1:3u\e[98u\e[98;1:3u")
      assert events == ["\e[97u", "\e[97;1:3u", "\e[98u", "\e[98;1:3u"]
    end

    test "Kitty arrow with event type", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[1;1:1A")
      assert events == ["\e[1;1:1A"]
    end

    test "Kitty functional key with event type", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[3;1:3~")
      assert events == ["\e[3;1:3~"]
    end

    test "plain char followed by Kitty release", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "a\e[97;1:3u")
      assert events == ["a", "\e[97;1:3u"]
    end

    test "Kitty sequence followed by plain char", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[97ua")
      assert events == ["\e[97u", "a"]
    end

    test "rapid typing simulation", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[104u\e[104;1:3u\e[105u\e[105;1:3u")
      assert events == ["\e[104u", "\e[104;1:3u", "\e[105u", "\e[105;1:3u"]
    end
  end

  describe "mouse events" do
    test "SGR mouse press", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[<0;10;5M")
      assert events == ["\e[<0;10;5M"]
    end

    test "SGR mouse release", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[<0;10;5m")
      assert events == ["\e[<0;10;5m"]
    end

    test "SGR mouse move", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[<35;20;5m")
      assert events == ["\e[<35;20;5m"]
    end

    test "split SGR mouse", %{fsm: fsm} do
      {fsm, _, _} = feed(fsm, "\e[<3")
      {fsm, _, _} = feed(fsm, "5;1")
      {fsm, _, _} = feed(fsm, "5;")
      {_fsm, events, _t} = feed(fsm, "10m")
      assert events == ["\e[<35;15;10m"]
    end

    test "multiple SGR mouse events", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[<35;1;1m\e[<35;2;2m\e[<35;3;3m")
      assert events == ["\e[<35;1;1m", "\e[<35;2;2m", "\e[<35;3;3m"]
    end

    test "old-style mouse (ESC[M + 3 bytes)", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[M abc")
      assert events == ["\e[M ab", "c"]
    end

    test "incomplete old-style mouse buffered across chunks", %{fsm: fsm} do
      {fsm, _, _} = feed(fsm, "\e[M")
      assert fsm.buffer == "\e[M"

      {fsm, _, _} = feed(fsm, " a")
      assert fsm.buffer == "\e[M a"

      {_fsm, events, _t} = feed(fsm, "b")
      assert events == ["\e[M ab"]
    end
  end

  describe "bracketed paste" do
    test "complete paste in one chunk", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[200~hello world\e[201~")
      assert "\e[200~" in events
      assert "\e[201~" in events
    end

    test "paste with unicode content", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[200~Hello 世界\e[201~")
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
      text = events |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join()
      assert text == "Hello 世界"
    end

    test "paste with newlines", %{fsm: fsm} do
      {_fsm, events, _t} = feed(fsm, "\e[200~line1\nline2\e[201~")
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
    end

    test "input before and after paste markers", %{fsm: fsm} do
      {fsm, e1, _} = feed(fsm, "a")
      {fsm, e2, _} = feed(fsm, "\e[200~pasted\e[201~")
      {_fsm, e3, _} = feed(fsm, "b")
      events = e1 ++ e2 ++ e3
      assert hd(events) == "a"
      assert List.last(events) == "b"
    end
  end

  describe "edge cases" do
    test "very long CSI sequence", %{fsm: fsm} do
      long_seq = "\e[" <> String.duplicate("1;", 50) <> "H"
      {_fsm, events, _t} = feed(fsm, long_seq)
      assert events == [long_seq]
    end

    test "empty binary is a no-op (no events, no buffer)", %{fsm: fsm} do
      {fsm, events, timeout} = feed(fsm, "")
      assert events == []
      assert timeout == :infinity
      assert fsm.buffer == ""
    end
  end

  describe "flush/1" do
    test "flushes incomplete sequences", %{fsm: fsm} do
      {fsm, _, _} = feed(fsm, "\e[<35")
      {fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == ["\e[<35"]
      assert fsm.buffer == ""
    end

    test "returns empty list when nothing to flush", %{fsm: fsm} do
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == []
    end
  end

  describe "clear/1" do
    test "clears buffer without emitting", %{fsm: fsm} do
      {fsm, _, _} = feed(fsm, "\e[<35")
      assert fsm.buffer == "\e[<35"

      fsm = StdinFSM.clear(fsm)
      assert fsm.buffer == ""
      {_fsm, flushed} = StdinFSM.flush(fsm)
      assert flushed == []
    end
  end
end
