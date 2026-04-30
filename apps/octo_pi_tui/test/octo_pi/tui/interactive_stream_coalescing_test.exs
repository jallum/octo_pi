defmodule OctoPi.TUI.InteractiveStreamCoalescingTest do
  @moduledoc """
  Tests for opi-4dx.3 + .6: pull-tick streaming coalescing.

  Block-delta events (MessageBlockStart/Delta/End) stash into
  `streaming_blocks` and stamp `streaming_tick_at` without updating
  the transcript. A periodic tick (or any non-block agent event)
  flushes pending state into the transcript via
  `Interactive.flush_pending_partial/1`.
  """

  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Usage
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp finalized(text) do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test",
      timestamp: 0,
      content: [%Content.Text{text: text}],
      usage: %Usage{},
      stop_reason: :stop
    }
  end

  defp base_state do
    %Interactive{
      transcript: [],
      theme: @theme,
      footer: %Footer{},
      streaming_blocks: %{order: [], data: %{}}
    }
  end

  defp delta(snapshot, block_id \\ 0) do
    %Event.MessageBlockDelta{
      block_id: block_id,
      kind: :text,
      delta: snapshot,
      snapshot: snapshot
    }
  end

  describe "block-delta stashing (no immediate render)" do
    test "stashes the snapshot and does not update transcript" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hel")})

      assert s1.streaming_blocks.data == %{0 => {:text, "Hel"}}
      assert s1.transcript == [], "transcript must not be updated by a block delta"
    end

    test "second delta replaces snapshot for the same block (latest wins)" do
      s0 = base_state()

      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("a")})
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, delta("ab")})

      assert s2.streaming_blocks.data == %{0 => {:text, "ab"}}
      assert s2.transcript == []
    end

    test "first delta arms streaming_tick_at; subsequent deltas leave the deadline alone" do
      s0 = base_state()
      now_before = System.monotonic_time(:millisecond)

      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("a")})
      assert is_integer(s1.streaming_tick_at)
      assert s1.streaming_tick_at >= now_before
      first_deadline = s1.streaming_tick_at

      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, delta("ab")})

      assert s2.streaming_tick_at == first_deadline,
             "deadline must not be re-armed on subsequent stashes"
    end
  end

  describe "flush_pending_partial/1" do
    test "applies pending blocks into transcript and clears the deadline" do
      s0 = base_state()

      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hello world")})

      s2 = Interactive.flush_pending_partial(s1)

      assert s2.streaming_tick_at == nil
      assert length(s2.transcript) == 1
      [msg] = s2.transcript
      assert %AssistantMessage{streaming?: true, content: [text: "Hello world"]} = msg
    end

    test "no-op when nothing pending" do
      s0 = base_state()
      s1 = Interactive.flush_pending_partial(s0)
      assert s1 == s0
    end
  end

  describe "ordering: non-block agent events flush pending first" do
    test "MessageEnd flushes pending and then finalizes" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hello")})
      assert s1.streaming_tick_at != nil

      ev_end = %Event.MessageEnd{message: finalized("Hello, world!")}
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_end})

      assert s2.streaming_tick_at == nil
      assert length(s2.transcript) == 1
      [msg] = s2.transcript
      assert %AssistantMessage{streaming?: false, finalized?: true} = msg
      assert msg.content == [{:text, "Hello, world!"}]
    end

    test "ToolExecutionStart flushes pending before appending the tool entry" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Calling…")})

      ev_tool = %Event.ToolExecutionStart{
        tool_call_id: "tc-1",
        tool_name: "read_file",
        args: %{path: "x"}
      }

      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_tool})

      assert s2.streaming_tick_at == nil
      # Pending blocks flushed first; tool execution appended after.
      assert length(s2.transcript) >= 2
      [first | _] = s2.transcript
      assert %AssistantMessage{} = first
    end
  end
end
