defmodule OctoPi.TUI.InteractiveStreamCoalescingTest do
  @moduledoc """
  Tests for opi-4dx.3: pull-tick streaming coalescing.

  MessageUpdate (per-chunk) events stash a partial in state without
  updating the transcript. A periodic streaming tick (or any other
  agent event) flushes the pending partial into the transcript via
  the existing apply_partial path.

  All tests target the pure handle_event/2 entry point or the new
  `Interactive.flush_pending_partial/1` helper. No GenServer needed.
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

  defp partial(text, response_id \\ "msg-123") do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "test",
      response_id: response_id,
      timestamp: 0,
      content: [%Content.Text{text: text}],
      usage: %Usage{}
    }
  end

  defp base_state do
    %Interactive{transcript: [], theme: @theme, footer: %Footer{}}
  end

  describe "MessageUpdate stashing (no immediate render)" do
    test "stashes partial and does not update transcript" do
      s0 = base_state()
      ev = %Event.MessageUpdate{partial: partial("Hel")}
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev})

      assert s1.pending_partial == ev.partial
      assert s1.transcript == [], "transcript must not be updated by MessageUpdate"
    end

    test "second MessageUpdate replaces pending_partial (latest wins, append-fold semantics)" do
      s0 = base_state()
      ev1 = %Event.MessageUpdate{partial: partial("a")}
      ev2 = %Event.MessageUpdate{partial: partial("ab")}

      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev1})
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev2})

      assert s2.pending_partial == ev2.partial
      assert s2.transcript == []
    end

    test "first MessageUpdate arms streaming_tick_at; subsequent updates leave deadline alone" do
      s0 = base_state()
      now_before = System.monotonic_time(:millisecond)

      ev1 = %Event.MessageUpdate{partial: partial("a")}
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev1})
      assert is_integer(s1.streaming_tick_at)
      assert s1.streaming_tick_at >= now_before
      first_deadline = s1.streaming_tick_at

      ev2 = %Event.MessageUpdate{partial: partial("ab")}
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev2})

      assert s2.streaming_tick_at == first_deadline,
             "deadline must not be re-armed on subsequent stashes"
    end
  end

  describe "flush_pending_partial/1" do
    test "applies pending into transcript and clears pending state" do
      s0 = base_state()

      ev = %Event.MessageUpdate{partial: partial("Hello world")}
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev})

      s2 = Interactive.flush_pending_partial(s1)

      assert s2.pending_partial == nil
      assert s2.streaming_tick_at == nil
      assert length(s2.transcript) == 1
      [msg] = s2.transcript
      assert %AssistantMessage{streaming?: true} = msg
      assert msg.msg_id == "msg-123"
    end

    test "no-op when nothing pending" do
      s0 = base_state()
      s1 = Interactive.flush_pending_partial(s0)
      assert s1 == s0
    end
  end

  describe "ordering: non-MessageUpdate agent events flush pending first" do
    test "MessageEnd flushes pending and then finalizes" do
      s0 = base_state()
      ev_update = %Event.MessageUpdate{partial: partial("Hello")}
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev_update})
      assert s1.pending_partial

      finalized = %{
        partial("Hello, world!")
        | stop_reason: :stop
      }

      ev_end = %Event.MessageEnd{message: finalized}
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_end})

      assert s2.pending_partial == nil
      assert s2.streaming_tick_at == nil
      assert length(s2.transcript) == 1
      [msg] = s2.transcript
      # `:stop` is not surfaced as a UI stop_reason — the TUI shows
      # `nil | :aborted | :error`. The load-bearing assertion is that
      # the message is no longer streaming and carries the finalized
      # content from the MessageEnd payload.
      assert %AssistantMessage{streaming?: false} = msg
      assert msg.content == [{:text, "Hello, world!"}]
    end

    test "ToolExecutionStart flushes pending before appending the tool entry" do
      s0 = base_state()
      ev_update = %Event.MessageUpdate{partial: partial("Calling…")}
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, ev_update})

      ev_tool = %Event.ToolExecutionStart{
        tool_call_id: "tc-1",
        tool_name: "read_file",
        args: %{path: "x"}
      }

      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_tool})

      assert s2.pending_partial == nil
      # Pending partial flushed in first; tool execution appended after.
      assert length(s2.transcript) >= 2
      [first | _] = s2.transcript
      assert %AssistantMessage{} = first
    end
  end
end
