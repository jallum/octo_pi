defmodule OctoPi.AITest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Content
  alias OctoPi.AI.Context
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Provider
  alias OctoPi.AI.Tool
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage

  describe "canonical contract modules are defined" do
    test "structs exist" do
      assert %Context{}

      assert %Model{
        id: "x",
        name: "x",
        api: :x,
        provider: :x,
        base_url: "x",
        context_window: 1,
        max_tokens: 1
      }

      assert %Tool{name: "n", description: "d", parameters: %{}}
      assert %ToolCall{id: "1", name: "t"}
      assert %Usage{}
      assert %Usage.Cost{}
      assert %CallOptions{}
      assert %Content.Text{}
      assert %Content.Thinking{}
      assert %Content.Image{data: "x", mime_type: "image/png"}
    end

    test "message structs exist" do
      assert %Message.User{content: "hi", timestamp: 0}

      assert %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude",
        timestamp: 0
      }

      assert %Message.ToolResult{
        tool_call_id: "1",
        tool_name: "t",
        content: [],
        is_error?: false,
        timestamp: 0
      }
    end

    test "event structs exist" do
      assistant = %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude",
        timestamp: 0
      }

      assert %Event.Start{partial: assistant}
      assert %Event.TextStart{content_index: 0, partial: assistant}
      assert %Event.TextDelta{content_index: 0, delta: "x", partial: assistant}
      assert %Event.TextEnd{content_index: 0, content: "x", partial: assistant}
      assert %Event.ThinkingStart{content_index: 0, partial: assistant}
      assert %Event.ThinkingDelta{content_index: 0, delta: "x", partial: assistant}
      assert %Event.ThinkingEnd{content_index: 0, content: "x", partial: assistant}
      assert %Event.ToolCallStart{content_index: 0, partial: assistant}
      assert %Event.ToolCallDelta{content_index: 0, delta: "x", partial: assistant}

      assert %Event.ToolCallEnd{
        content_index: 0,
        tool_call: %ToolCall{id: "1", name: "t"},
        partial: assistant
      }

      assert %Event.Done{reason: :stop, message: assistant}
      assert %Event.Error{reason: :error, message: assistant}
    end

    test "provider behaviour defines stream_to/5" do
      callbacks = Provider.behaviour_info(:callbacks)
      assert {:stream_to, 5} in callbacks
    end
  end
end
