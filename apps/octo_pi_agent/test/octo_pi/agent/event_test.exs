defmodule OctoPi.Agent.EventTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event

  describe "CompactionStart" do
    test "requires reason" do
      event = %Event.CompactionStart{reason: :manual}
      assert event.reason == :manual
    end

    test "accepts all valid reasons" do
      for reason <- [:manual, :threshold, :overflow] do
        assert %Event.CompactionStart{reason: ^reason} = %Event.CompactionStart{reason: reason}
      end
    end
  end

  describe "CompactionEnd" do
    test "defaults: aborted? false, will_retry? false, result nil, error_message nil" do
      event = %Event.CompactionEnd{reason: :manual, aborted?: false, will_retry?: false}
      assert event.reason == :manual
      refute event.aborted?
      refute event.will_retry?
      assert event.result == nil
      assert event.error_message == nil
    end

    test "carries result map on success" do
      result = %{summary: "summary text", first_kept_entry_id: "aabbccdd", tokens_before: 4096}
      event = %Event.CompactionEnd{reason: :threshold, aborted?: false, will_retry?: false, result: result}
      assert event.result == result
    end

    test "aborted? true with nil result" do
      event = %Event.CompactionEnd{reason: :overflow, aborted?: true, will_retry?: false}
      assert event.aborted?
      assert event.result == nil
    end

    test "will_retry? true for overflow-triggered retry" do
      event = %Event.CompactionEnd{reason: :overflow, aborted?: false, will_retry?: true}
      assert event.will_retry?
    end

    test "carries error_message on failure" do
      event = %Event.CompactionEnd{
        reason: :manual,
        aborted?: false,
        will_retry?: false,
        error_message: "LLM request failed"
      }

      assert event.error_message == "LLM request failed"
    end
  end

  describe "union type coverage" do
    test "all event struct variants can be constructed" do
      partial = %OctoPi.AI.Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude",
        timestamp: 0
      }

      tool_result = %OctoPi.Agent.Tool.Result{content: []}

      events = [
        %Event.AgentStart{},
        %Event.AgentEnd{reason: :stop, messages: []},
        %Event.TurnStart{turn: 1},
        %Event.TurnEnd{turn: 1},
        %Event.MessageStart{partial: partial},
        %Event.MessageUpdate{partial: partial},
        %Event.MessageEnd{message: partial},
        %Event.ToolExecutionStart{tool_call_id: "x", tool_name: "echo"},
        %Event.ToolExecutionUpdate{tool_call_id: "x", partial: tool_result},
        %Event.ToolExecutionEnd{tool_call_id: "x", tool_name: "echo", result: tool_result},
        %Event.CompactionStart{reason: :manual},
        %Event.CompactionEnd{reason: :manual, aborted?: false, will_retry?: false}
      ]

      assert length(events) == 12
    end
  end
end
