defmodule OctoPi.TUI.StdinFSMTest do
  use ExUnit.Case, async: false

  alias OctoPi.TUI.StdinFSM

  setup do
    {:ok, pid} = StdinFSM.start_link(subscriber: self(), flush_ms: 20)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    {:ok, fsm: pid}
  end

  # Drain only the events already sitting in the mailbox — don't wait
  # for async flushes. Tests that care about flush timing use
  # assert_receive with an explicit bound.
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
  end

  describe "idle flush timeout" do
    test "bare ESC sits until timeout, then emits", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e")
      assert drain() == []
      # flush_ms is 20 in setup; assert_receive waits up to 100ms
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
  end

  describe "OSC sequence" do
    test "\\e]0;title\\x07 (BEL terminator)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e]0;hello\x07")
      assert drain() == ["\e]0;hello\x07"]
    end

    test "\\e]... \\e\\\\ (ST terminator)", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\e]0;x\e\\")
      assert drain() == ["\e]0;x\e\\"]
    end
  end

  describe "meta (ESC + char) vs CSI" do
    test "ESC followed by a letter that isn't [ or O is a meta sequence", %{fsm: fsm} do
      :ok = StdinFSM.process(fsm, "\eb")
      # Buffer keeps "\eb" and waits for timeout, then flushes —
      # upstream treats this as Meta+b. We don't model meta keys in
      # MVP (deferred to 4.1), so the timeout path is correct.
      assert_receive {:stdin_event, "\eb"}, 100
    end
  end
end
