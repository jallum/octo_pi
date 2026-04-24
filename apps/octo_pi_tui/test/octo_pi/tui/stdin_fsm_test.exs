defmodule OctoPi.TUI.StdinFSMTest do
  use ExUnit.Case, async: false

  alias OctoPi.TUI.StdinFSM

  setup do
    {:ok, pid} = StdinFSM.start_link(subscriber: self(), flush_ms: 20)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, fsm: pid}
  end

  defp drain, do: drain([])

  defp drain(acc) do
    receive do
      {:stdin_event, bin} -> drain([bin | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "printable chars" do
    test "single ASCII", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "a")
      assert drain() == ["a"]
    end

    test "run of ASCII", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "abc")
      assert drain() == ["a", "b", "c"]
    end

    test "UTF-8 codepoint (accented)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "é")
      assert drain() == ["é"]
    end

    test "UTF-8 codepoint (CJK)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "日本語")
      assert drain() == ["日", "本", "語"]
    end

    test "mixed ASCII + UTF-8", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "aé日")
      assert drain() == ["a", "é", "日"]
    end

    test "unicode hello 世界", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "hello 世界")
      assert drain() == ["h", "e", "l", "l", "o", " ", "世", "界"]
    end
  end

  describe "complete escape sequences in one chunk" do
    test "CSI up arrow", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[A")
      assert drain() == ["\e[A"]
    end

    test "CSI F1 (\\e[11~)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[11~")
      assert drain() == ["\e[11~"]
    end

    test "SS3 arrow (\\eOA)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\eOA")
      assert drain() == ["\eOA"]
    end

    test "bracketed paste start marker", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[200~")
      assert drain() == ["\e[200~"]
    end

    test "meta key sequence (\\ea)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\ea")
      assert drain() == ["\ea"]
    end

    test "multiple sequences in one chunk", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "a\e[Ab")
      assert drain() == ["a", "\e[A", "b"]
    end
  end

  describe "sequences split across chunks" do
    test "ESC then [A", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e")
      assert drain() == []
      :ok = StdinFSM.process(fsm, "[A")
      assert drain() == ["\e[A"]
    end

    test "ESC[ then A", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[")
      assert drain() == []
      :ok = StdinFSM.process(fsm, "A")
      assert drain() == ["\e[A"]
    end

    test "many tiny chunks", %{fsm: fsm} do
      for byte <- String.graphemes("\e[11~"), do: :ok = StdinFSM.process(fsm, byte)
      assert drain() == ["\e[11~"]
    end

    test "chunks with text before and after the sequence", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "hi\e")
      :ok = StdinFSM.process(fsm, "[A")
      :ok = StdinFSM.process(fsm, "there")
      assert drain() == ["h", "i", "\e[A", "t", "h", "e", "r", "e"]
    end

    test "incomplete mouse SGR split across 3 chunks", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e")
      assert drain() == []
      assert StdinFSM.get_buffer(fsm) == "\e"

      :ok = StdinFSM.process(fsm, "[<35")
      assert drain() == []
      assert StdinFSM.get_buffer(fsm) == "\e[<35"

      :ok = StdinFSM.process(fsm, ";20;5m")
      assert drain() == ["\e[<35;20;5m"]
      assert StdinFSM.get_buffer(fsm) == ""
    end

    test "incomplete CSI reassembled from 3 chunks", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[")
      assert drain() == []
      :ok = StdinFSM.process(fsm, "1;")
      assert drain() == []
      :ok = StdinFSM.process(fsm, "5H")
      assert drain() == ["\e[1;5H"]
    end

    test "split across many tiny chunks (SGR mouse)", %{fsm: fsm} do
      for byte <- ["\e", "[", "<", "3", "5", ";", "2", "0", ";", "5", "m"] do
        :ok = StdinFSM.process(fsm, byte)
      end

      assert drain() == ["\e[<35;20;5m"]
    end
  end

  describe "idle flush timeout" do
    test "bare ESC sits until timeout, then emits", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e")
      assert drain() == []
      assert_receive {:stdin_event, "\e"}, 100
    end

    test "partial CSI sits until timeout, then emits as-is", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[")
      assert drain() == []
      assert_receive {:stdin_event, "\e["}, 100
    end

    test "a completed sequence followed by a partial ESC flushes only the partial", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[A\e")
      assert_receive {:stdin_event, "\e[A"}, 100
      assert_receive {:stdin_event, "\e"}, 100
    end

    test "incomplete partial sequence flushes after timeout", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35")
      assert drain() == []
      assert_receive {:stdin_event, "\e[<35"}, 100
    end
  end

  describe "mixed content" do
    test "chars followed by escape sequence", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "abc\e[A")
      assert drain() == ["a", "b", "c", "\e[A"]
    end

    test "escape sequence followed by chars", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[Aabc")
      assert drain() == ["\e[A", "a", "b", "c"]
    end

    test "multiple complete sequences", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[A\e[B\e[C")
      assert drain() == ["\e[A", "\e[B", "\e[C"]
    end

    test "partial sequence with preceding chars", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "abc\e[<35")
      assert drain() == ["a", "b", "c"]
      assert StdinFSM.get_buffer(fsm) == "\e[<35"

      :ok = StdinFSM.process(fsm, ";20;5m")
      assert drain() == ["\e[<35;20;5m"]
    end
  end

  describe "OSC sequences" do
    test "\\e]0;title\\x07 (BEL terminator)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e]0;hello\x07")
      assert drain() == ["\e]0;hello\x07"]
    end

    test "\\e]... \\e\\\\ (ST terminator)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e]0;x\e\\")
      assert drain() == ["\e]0;x\e\\"]
    end
  end

  describe "alt-prefix (ESC + char)" do
    test "ESC + letter emits immediately", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\eb")
      assert drain() == ["\eb"]
    end

    test "ESC + space", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e ")
      assert drain() == ["\e "]
    end

    test "ESC + backspace", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e\b")
      assert drain() == ["\e\b"]
    end

    test "ESC + Ctrl+C (ctrl+alt+c)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e\x03")
      assert drain() == ["\e\x03"]
    end

    test "ESC + ESC (ctrl+alt+[)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e\e")
      assert drain() == ["\e\e"]
    end

    test "alt+a followed by alt+z", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\ea\ez")
      assert drain() == ["\ea", "\ez"]
    end

    test "alt+1", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e1")
      assert drain() == ["\e1"]
    end
  end

  describe "Kitty keyboard protocol" do
    test "Kitty CSI-u press event", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[97u")
      assert drain() == ["\e[97u"]
    end

    test "Kitty CSI-u release event", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[97;1:3u")
      assert drain() == ["\e[97;1:3u"]
    end

    test "batched Kitty press and release", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[97u\e[97;1:3u")
      assert drain() == ["\e[97u", "\e[97;1:3u"]
    end

    test "multiple batched Kitty events", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[97u\e[97;1:3u\e[98u\e[98;1:3u")
      assert drain() == ["\e[97u", "\e[97;1:3u", "\e[98u", "\e[98;1:3u"]
    end

    test "Kitty arrow with event type", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[1;1:1A")
      assert drain() == ["\e[1;1:1A"]
    end

    test "Kitty functional key with event type", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[3;1:3~")
      assert drain() == ["\e[3;1:3~"]
    end

    test "plain char followed by Kitty release", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "a\e[97;1:3u")
      assert drain() == ["a", "\e[97;1:3u"]
    end

    test "Kitty sequence followed by plain char", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[97ua")
      assert drain() == ["\e[97u", "a"]
    end

    test "rapid typing simulation", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[104u\e[104;1:3u\e[105u\e[105;1:3u")
      assert drain() == ["\e[104u", "\e[104;1:3u", "\e[105u", "\e[105;1:3u"]
    end
  end

  describe "mouse events" do
    test "SGR mouse press", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<0;10;5M")
      assert drain() == ["\e[<0;10;5M"]
    end

    test "SGR mouse release", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<0;10;5m")
      assert drain() == ["\e[<0;10;5m"]
    end

    test "SGR mouse move", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35;20;5m")
      assert drain() == ["\e[<35;20;5m"]
    end

    test "split SGR mouse", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<3")
      :ok = StdinFSM.process(fsm, "5;1")
      :ok = StdinFSM.process(fsm, "5;")
      :ok = StdinFSM.process(fsm, "10m")
      assert drain() == ["\e[<35;15;10m"]
    end

    test "multiple SGR mouse events", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35;1;1m\e[<35;2;2m\e[<35;3;3m")
      assert drain() == ["\e[<35;1;1m", "\e[<35;2;2m", "\e[<35;3;3m"]
    end

    test "old-style mouse (ESC[M + 3 bytes)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[M abc")
      assert drain() == ["\e[M ab", "c"]
    end

    test "incomplete old-style mouse buffered across chunks", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[M")
      assert StdinFSM.get_buffer(fsm) == "\e[M"

      :ok = StdinFSM.process(fsm, " a")
      assert StdinFSM.get_buffer(fsm) == "\e[M a"

      :ok = StdinFSM.process(fsm, "b")
      assert drain() == ["\e[M ab"]
    end
  end

  describe "bracketed paste" do
    test "complete paste in one chunk", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[200~hello world\e[201~")
      events = drain()
      assert "\e[200~" in events
      assert "\e[201~" in events
    end

    test "paste with unicode content", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[200~Hello 世界\e[201~")
      events = drain()
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
      text = events |> Enum.drop(1) |> Enum.drop(-1) |> Enum.join()
      assert text == "Hello 世界"
    end

    test "paste with newlines", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[200~line1\nline2\e[201~")
      events = drain()
      assert hd(events) == "\e[200~"
      assert List.last(events) == "\e[201~"
    end

    test "input before and after paste markers", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "a")
      :ok = StdinFSM.process(fsm, "\e[200~pasted\e[201~")
      :ok = StdinFSM.process(fsm, "b")
      events = drain()
      assert hd(events) == "a"
      assert List.last(events) == "b"
    end
  end

  describe "edge cases" do
    test "very long CSI sequence", %{fsm: fsm} do
      long_seq = "\e[" <> String.duplicate("1;", 50) <> "H"
      :ok = StdinFSM.process(fsm, long_seq)
      assert drain() == [long_seq]
    end

    test "lone escape flushed by explicit flush", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e")
      assert drain() == []
      assert StdinFSM.flush(fsm) == ["\e"]
    end

    test "empty binary is a no-op (no events, no buffer)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "")
      assert drain() == []
      assert StdinFSM.get_buffer(fsm) == ""
    end
  end

  describe "lifecycle cleanup" do
    test "stopping the FSM does not emit buffered partial after stop" do
      {:ok, pid} = StdinFSM.start_link(subscriber: self(), flush_ms: 20)
      :ok = StdinFSM.process(pid, "\e[<35")
      assert StdinFSM.get_buffer(pid) == "\e[<35"
      GenServer.stop(pid)
      refute_receive {:stdin_event, _}, 60
    end
  end

  describe "flush/1" do
    test "flushes incomplete sequences", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35")
      flushed = StdinFSM.flush(fsm)
      assert flushed == ["\e[<35"]
      assert StdinFSM.get_buffer(fsm) == ""
    end

    test "returns empty list when nothing to flush", %{fsm: fsm} do
      assert StdinFSM.flush(fsm) == []
    end

    test "also emits to subscriber", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35")
      _flushed = StdinFSM.flush(fsm)
      assert_receive {:stdin_event, "\e[<35"}, 100
    end
  end

  describe "clear/1" do
    test "clears buffer without emitting", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e[<35")
      assert StdinFSM.get_buffer(fsm) == "\e[<35"

      :ok = StdinFSM.clear(fsm)
      assert StdinFSM.get_buffer(fsm) == ""
      assert drain() == []
    end
  end
end
