defmodule OctoPi.TUI.InteractiveStreamCoalescingTest do
  @moduledoc """
  Tests for opi-4dx.13: streaming-tick coalescing on the flat
  Transcript.

  Block-delta events update the top-level Transcript directly
  (latest-snapshot-wins is the natural property of Transcript.update —
  only one slot mutates). The streaming-tick deadline is stamped so
  the eventual `:timeout` fires a single render rather than rendering
  per-delta.
  """

  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Usage
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Transcript
  alias OctoPi.TUI.Transcript.AssistantHeader
  alias OctoPi.TUI.Transcript.AssistantStatus
  alias OctoPi.TUI.Components.AssistantMessage.TextBlock

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

  # A state with one open turn (i.e. MessageStart already processed) so
  # block-delta events have a current_msg_id to compose keys against.
  defp base_state do
    %Interactive{transcript: %Transcript{}, theme: @theme, footer: %Footer{}}
    |> Interactive.handle_event({:octo_pi_agent_event, %Event.MessageStart{partial: nil}})
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
    test "updates the Transcript slot for that block_id with the latest snapshot" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hel")})

      key = "#{s1.current_msg_id}:0"
      assert Transcript.fetch_data!(s1.transcript, key) == "Hel"
    end

    test "second delta replaces snapshot for the same block (latest wins)" do
      s0 = base_state()

      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("a")})
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, delta("ab")})

      key = "#{s2.current_msg_id}:0"
      assert Transcript.fetch_data!(s2.transcript, key) == "ab"

      # Only one block slot exists for this turn — latest wins.
      block_keys = Enum.filter(s2.transcript.order, &String.ends_with?(&1, ":0"))
      assert length(block_keys) == 1
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

    test "block uses the TextBlock renderer module for :text" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("hi")})

      key = "#{s1.current_msg_id}:0"
      assert Transcript.fetch_module!(s1.transcript, key) == TextBlock
    end
  end

  describe "flush_pending_partial/1" do
    test "clears the deadline (no-op on data — Transcript is the live source)" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hello world")})

      key = "#{s1.current_msg_id}:0"
      assert Transcript.fetch_data!(s1.transcript, key) == "Hello world"
      assert s1.streaming_tick_at != nil

      s2 = Interactive.flush_pending_partial(s1)

      assert s2.streaming_tick_at == nil
      # The data is unchanged — there's nothing to flush in the .13 design.
      assert s2.transcript == s1.transcript
    end
  end

  describe "MessageEnd finalizes the turn" do
    test "appends an AssistantStatus entry and finalizes header + status" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Hello")})
      msg_id = s1.current_msg_id

      ev_end = %Event.MessageEnd{message: finalized("Hello, world!")}
      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_end})

      assert s2.streaming_tick_at == nil
      assert s2.current_msg_id == nil

      header_key = "#{msg_id}:hdr"
      status_key = "#{msg_id}:end"

      assert %AssistantHeader{msg_id: ^msg_id} = Transcript.fetch_data!(s2.transcript, header_key)
      assert %AssistantStatus{stop_reason: nil} = Transcript.fetch_data!(s2.transcript, status_key)

      refute MapSet.member?(s2.transcript.streaming, header_key)
      refute MapSet.member?(s2.transcript.streaming, status_key)
    end
  end

  describe "ToolExecutionStart appends a sibling tool entry mid-stream" do
    test "tool entry is appended after the streaming blocks" do
      s0 = base_state()
      s1 = Interactive.handle_event(s0, {:octo_pi_agent_event, delta("Calling…")})

      ev_tool = %Event.ToolExecutionStart{
        tool_call_id: "tc-1",
        tool_name: "read_file",
        args: %{path: "x"}
      }

      s2 = Interactive.handle_event(s1, {:octo_pi_agent_event, ev_tool})

      tool_key = "tool:tc-1"
      assert Transcript.has_entry?(s2.transcript, tool_key)
      # Tool entry order index is later than the block entry's.
      assert Enum.find_index(Enum.reverse(s2.transcript.order), &(&1 == tool_key)) >
               Enum.find_index(Enum.reverse(s2.transcript.order), &String.ends_with?(&1, ":0"))
    end
  end
end
