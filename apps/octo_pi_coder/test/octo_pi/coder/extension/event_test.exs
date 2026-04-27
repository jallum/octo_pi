defmodule OctoPi.Coder.Extension.EventTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Event

  describe "event_types/0" do
    test "returns all 28 event types" do
      types = Event.event_types()
      assert length(types) == 28
      assert :session_start in types
      assert :tool_call in types
      assert :resources_discover in types
    end
  end

  describe "pattern/1" do
    test "fire-and-forget events" do
      for t <- [
            :session_start,
            :session_shutdown,
            :session_compact,
            :session_tree,
            :agent_start,
            :agent_end,
            :turn_start,
            :turn_end,
            :message_start,
            :message_update,
            :message_end,
            :tool_execution_start,
            :tool_execution_update,
            :tool_execution_end,
            :model_select,
            :after_provider_response
          ] do
        assert :fire_and_forget == Event.pattern(t), "expected #{t} to be fire_and_forget"
      end
    end

    test "cancel-on-result events" do
      for t <- [
            :session_before_switch,
            :session_before_fork,
            :session_before_compact,
            :session_before_tree
          ] do
        assert :halt_on_result == Event.pattern(t), "expected #{t} to be halt_on_result"
      end
    end

    test "reduce-chain events" do
      for t <- [:context, :before_provider_request, :input] do
        assert :reduce_chain == Event.pattern(t), "expected #{t} to be reduce_chain"
      end
    end

    test "mutate-in-place events" do
      assert :mutate_in_place == Event.pattern(:tool_call)
    end

    test "patch-merge events" do
      assert :patch_merge == Event.pattern(:tool_result)
    end

    test "first-result events" do
      assert :first_result == Event.pattern(:user_bash)
    end

    test "collect-all events" do
      assert :collect_all == Event.pattern(:before_agent_start)
      assert :collect_all == Event.pattern(:resources_discover)
    end

    test "raises on unknown event" do
      assert_raise ArgumentError, ~r/unknown event type/, fn ->
        Event.pattern(:not_a_thing)
      end
    end
  end

  describe "valid?/1" do
    test "returns true for known events" do
      assert Event.valid?(:session_start)
      assert Event.valid?(:tool_call)
    end

    test "returns false for unknown events" do
      refute Event.valid?(:nope)
    end
  end

  describe "new/2" do
    test "creates event map with type and payload" do
      event = Event.new(:session_start, %{reason: :new})
      assert event.type == :session_start
      assert event.reason == :new
    end

    test "rejects unknown event type" do
      assert_raise ArgumentError, ~r/unknown event type/, fn ->
        Event.new(:fake, %{})
      end
    end
  end
end
