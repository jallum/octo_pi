defmodule OctoPi.AI.Providers.Anthropic.DecoderTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.{Content, Event, Message, Model, ToolCall}
  alias OctoPi.AI.Providers.Anthropic.Decoder

  defp model do
    %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 64_000
    }
  end

  defp feed(state, events) do
    Enum.reduce(events, {[], state}, fn anthropic_event, {acc, st} ->
      {events, st} = Decoder.handle(st, anthropic_event)
      {acc ++ events, st}
    end)
  end

  describe "new/1" do
    test "emits a :start event with an empty partial message" do
      {start, state} = Decoder.new(model())

      assert %Event.Start{partial: %Message.Assistant{} = partial} = start
      assert partial.api == :anthropic_messages
      assert partial.provider == :anthropic
      assert partial.model == "claude-haiku-4-5"
      assert partial.content == []
      assert partial.stop_reason == nil
      assert partial.response_id == nil
      assert is_integer(partial.timestamp)

      # State tracks the same partial.
      assert state.message == partial
    end
  end

  describe "handle/2 — message_start" do
    test "captures response_id and seeds usage without emitting an event" do
      {_, state} = Decoder.new(model())

      msg_start = %{
        "type" => "message_start",
        "message" => %{
          "id" => "msg_abc123",
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 0,
            "cache_read_input_tokens" => 5,
            "cache_creation_input_tokens" => 2
          }
        }
      }

      {events, state} = Decoder.handle(state, msg_start)

      assert events == []
      assert state.message.response_id == "msg_abc123"
      assert state.message.usage.input == 12
      assert state.message.usage.output == 0
      assert state.message.usage.cache_read == 5
      assert state.message.usage.cache_write == 2
      assert state.message.usage.total_tokens == 19
    end

    test "treats missing usage fields as zero" do
      {_, state} = Decoder.new(model())

      msg_start = %{
        "type" => "message_start",
        "message" => %{"id" => "msg_x", "usage" => %{"input_tokens" => 7}}
      }

      {[], state} = Decoder.handle(state, msg_start)

      assert state.message.usage.input == 7
      assert state.message.usage.output == 0
      assert state.message.usage.cache_read == 0
      assert state.message.usage.cache_write == 0
      assert state.message.usage.total_tokens == 7
    end
  end

  describe "handle/2 — text block lifecycle" do
    test "emits text_start, text_delta, text_end in order" do
      {_, state} = Decoder.new(model())

      {events, state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "Hello "}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "world"}
          },
          %{"type" => "content_block_stop", "index" => 0}
        ])

      assert [
               %Event.TextStart{content_index: 0},
               %Event.TextDelta{content_index: 0, delta: "Hello "},
               %Event.TextDelta{content_index: 0, delta: "world"},
               %Event.TextEnd{content_index: 0, content: "Hello world"}
             ] = events

      assert [%Content.Text{text: "Hello world"}] = state.message.content
    end
  end

  describe "handle/2 — thinking block lifecycle" do
    test "emits thinking_start, thinking_delta, thinking_end and carries signature" do
      {_, state} = Decoder.new(model())

      {events, state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "thinking"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "Let me "}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "thinking_delta", "thinking" => "think..."}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "sig-part-"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "signature_delta", "signature" => "1"}
          },
          %{"type" => "content_block_stop", "index" => 0}
        ])

      assert [
               %Event.ThinkingStart{content_index: 0},
               %Event.ThinkingDelta{delta: "Let me "},
               %Event.ThinkingDelta{delta: "think..."},
               %Event.ThinkingEnd{content: "Let me think..."}
             ] = events

      assert [%Content.Thinking{thinking: "Let me think...", signature: "sig-part-1"}] =
               state.message.content
    end

    test "redacted_thinking carries placeholder + encrypted data" do
      {_, state} = Decoder.new(model())

      {events, state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "redacted_thinking", "data" => "encrypted-blob"}
          },
          %{"type" => "content_block_stop", "index" => 0}
        ])

      assert [
               %Event.ThinkingStart{content_index: 0},
               %Event.ThinkingEnd{content: "[Reasoning redacted]"}
             ] = events

      assert [
               %Content.Thinking{
                 thinking: "[Reasoning redacted]",
                 signature: "encrypted-blob",
                 redacted?: true
               }
             ] = state.message.content
    end
  end

  describe "handle/2 — tool_use block lifecycle" do
    test "accumulates partial_json and finalizes arguments on content_block_stop" do
      {_, state} = Decoder.new(model())

      {events, state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_edit_1",
              "name" => "edit",
              "input" => %{}
            }
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":)}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("README.md",)}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => ~s("text":"hi"})}
          },
          %{"type" => "content_block_stop", "index" => 0}
        ])

      # Find the ToolCallEnd event to verify final arguments.
      assert %Event.ToolCallEnd{tool_call: tool_call} = List.last(events)
      assert tool_call.id == "toolu_edit_1"
      assert tool_call.name == "edit"
      assert tool_call.arguments == %{"path" => "README.md", "text" => "hi"}

      # Final content reflects the finalized arguments, and the scratch
      # partial_json map is cleared.
      assert [%ToolCall{arguments: %{"path" => "README.md", "text" => "hi"}}] =
               state.message.content

      assert state.partial_json == %{}
    end

    test "pi-mono fixture: malformed input_json_delta (\\H + raw tab)" do
      # Ported from tmp/pi-mono/packages/ai/test/anthropic-sse-parsing.test.ts:43-111.
      # The partial_json contains an invalid `\H` escape and a literal
      # tab character inside a string — both should be repaired by
      # PartialJson.parse_streaming and yield the expected arguments.
      {_, state} = Decoder.new(model())

      partial_json = ~s({"path":"A\\H","text":"col1\tcol2"})

      {events, _state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "toolu_test",
              "name" => "edit",
              "input" => %{}
            }
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "input_json_delta", "partial_json" => partial_json}
          },
          %{"type" => "content_block_stop", "index" => 0}
        ])

      assert %Event.ToolCallEnd{tool_call: %ToolCall{arguments: args}} = List.last(events)
      assert args == %{"path" => "A\\H", "text" => "col1\tcol2"}
    end
  end

  describe "handle/2 — multiple interleaved content blocks" do
    test "tracks separate blocks by anthropic index" do
      {_, state} = Decoder.new(model())

      {events, state} =
        feed(state, [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 0,
            "delta" => %{"type" => "text_delta", "text" => "first"}
          },
          %{"type" => "content_block_stop", "index" => 0},
          %{
            "type" => "content_block_start",
            "index" => 1,
            "content_block" => %{"type" => "text"}
          },
          %{
            "type" => "content_block_delta",
            "index" => 1,
            "delta" => %{"type" => "text_delta", "text" => "second"}
          },
          %{"type" => "content_block_stop", "index" => 1}
        ])

      indices = events |> Enum.map(& &1.content_index) |> Enum.uniq()
      assert indices == [0, 1]

      assert [%Content.Text{text: "first"}, %Content.Text{text: "second"}] =
               state.message.content
    end
  end

  describe "handle/2 — message_delta" do
    test "sets stop_reason and merges non-null usage fields" do
      {_, state} = Decoder.new(model())

      {_, state} =
        Decoder.handle(state, %{
          "type" => "message_start",
          "message" => %{
            "id" => "m",
            "usage" => %{"input_tokens" => 10, "output_tokens" => 0}
          }
        })

      {events, state} =
        Decoder.handle(state, %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{"output_tokens" => 5}
        })

      assert events == []
      assert state.message.stop_reason == :tool_use
      # input_tokens preserved from message_start since delta omitted it.
      assert state.message.usage.input == 10
      assert state.message.usage.output == 5
      assert state.message.usage.total_tokens == 15
    end
  end

  describe "handle/2 — unknown / ignored events" do
    test "message_stop is silently ignored" do
      {_, state} = Decoder.new(model())

      {events, state_after} = Decoder.handle(state, %{"type" => "message_stop"})
      assert events == []
      assert state_after == state
    end

    test "ping event is silently ignored" do
      {_, state} = Decoder.new(model())

      {events, state_after} = Decoder.handle(state, %{"type" => "ping"})
      assert events == []
      assert state_after == state
    end

    test "completely unknown types are ignored" do
      {_, state} = Decoder.new(model())

      {events, _} = Decoder.handle(state, %{"type" => "future_event_type"})
      assert events == []
    end
  end

  describe "finalize/1" do
    test "emits Done for successful stop reasons" do
      {_, state} = Decoder.new(model())

      for reason <- [:stop, :length, :tool_use] do
        state_with_reason = %{state | message: %{state.message | stop_reason: reason}}
        assert %Event.Done{reason: ^reason} = Decoder.finalize(state_with_reason)
      end
    end

    test "emits Error for error/aborted stop reasons" do
      {_, state} = Decoder.new(model())

      for reason <- [:error, :aborted] do
        state_with_reason = %{state | message: %{state.message | stop_reason: reason}}
        assert %Event.Error{reason: ^reason} = Decoder.finalize(state_with_reason)
      end
    end

    test "emits Error when no stop_reason ever arrived" do
      {_, state} = Decoder.new(model())

      assert %Event.Error{reason: :error, message: msg} = Decoder.finalize(state)
      assert msg.stop_reason == :error
      assert msg.error_message =~ "stream ended"
    end
  end

  describe "error/3" do
    test "returns an Error event carrying the reason and message" do
      {_, state} = Decoder.new(model())

      {event, new_state} = Decoder.error(state, "boom", :error)
      assert %Event.Error{reason: :error, message: msg} = event
      assert msg.error_message == "boom"
      assert msg.stop_reason == :error
      assert new_state.message.error_message == "boom"
    end

    test "supports :aborted" do
      {_, state} = Decoder.new(model())

      {%Event.Error{reason: :aborted}, _} = Decoder.error(state, "cancelled", :aborted)
    end
  end

  describe "stop reason mapping (via message_delta)" do
    for {anthropic, canonical} <- [
          {"end_turn", :stop},
          {"stop_sequence", :stop},
          {"pause_turn", :stop},
          {"max_tokens", :length},
          {"tool_use", :tool_use},
          {"refusal", :error},
          {"sensitive", :error}
        ] do
      test "#{anthropic} maps to #{canonical}" do
        {_, state} = Decoder.new(model())

        {_, state} =
          Decoder.handle(state, %{
            "type" => "message_delta",
            "delta" => %{"stop_reason" => unquote(anthropic)},
            "usage" => %{}
          })

        assert state.message.stop_reason == unquote(canonical)
      end
    end

    test "unknown stop_reason raises — do not silently drop new API values" do
      {_, state} = Decoder.new(model())

      assert_raise ArgumentError, ~r/unknown Anthropic stop_reason/, fn ->
        Decoder.handle(state, %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "brand_new_value"},
          "usage" => %{}
        })
      end
    end
  end

  describe "full pi-mono fixture — tool_use streaming end-to-end" do
    # Ported from tmp/pi-mono/packages/ai/test/anthropic-sse-parsing.test.ts:27-112.
    # Walks the Decoder through the exact sequence of Anthropic events
    # that upstream test sends via its fake SSE response, and asserts
    # the finalized message matches.
    test "produces the expected final message" do
      {start_event, state} = Decoder.new(model())
      assert %Event.Start{} = start_event

      anthropic_events = [
        %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_test",
            "usage" => %{
              "input_tokens" => 12,
              "output_tokens" => 0,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0
            }
          }
        },
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_test",
            "name" => "edit",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{
            "type" => "input_json_delta",
            "partial_json" => ~s({"path":"A\\H","text":"col1\tcol2"})
          }
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{
            "input_tokens" => 12,
            "output_tokens" => 5,
            "cache_read_input_tokens" => 0,
            "cache_creation_input_tokens" => 0
          }
        },
        %{"type" => "message_stop"}
      ]

      {_events, state} = feed(state, anthropic_events)

      assert %Event.Done{reason: :tool_use, message: final} = Decoder.finalize(state)
      assert final.error_message == nil
      assert final.response_id == "msg_test"
      assert final.stop_reason == :tool_use
      assert final.usage.input == 12
      assert final.usage.output == 5

      assert [%ToolCall{id: "toolu_test", name: "edit", arguments: args}] = final.content
      assert args == %{"path" => "A\\H", "text" => "col1\tcol2"}
    end
  end
end
