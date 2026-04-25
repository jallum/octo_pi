defmodule OctoPi.AI.Providers.Anthropic.DecoderTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.Anthropic.Decoder
  alias OctoPi.AI.ToolCall

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

      # `state.message.content` is reverse-ordered during streaming
      # (open block at head); use Decoder.message/1 for forward order.
      assert [%Content.Text{text: "first"}, %Content.Text{text: "second"}] =
               Decoder.message(state).content
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

    test "raises ArgumentError when no stop_reason ever arrived" do
      # Before opi-hgb.9 we silently synthesized an :error event on nil.
      # Now we raise so a protocol-violating stream (or a new Anthropic
      # event ordering we haven't handled) surfaces loudly. The
      # Producer's rescue catches this and surfaces it as Event.Error —
      # separately tested in producer_test.exs.
      {_, state} = Decoder.new(model())

      assert_raise ArgumentError, ~r/stream ended without stop_reason/, fn ->
        Decoder.finalize(state)
      end
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

  describe "OAuth inbound tool-name reverse normalization" do
    alias OctoPi.AI.Tool

    test "without oauth?, names pass through unchanged" do
      {_, state} =
        Decoder.new(model(), tools: [%Tool{name: "todowrite", description: "", parameters: %{}}])

      {events, _} =
        Decoder.handle(state, %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "TodoWrite",
            "input" => %{}
          }
        })

      assert [%Event.ToolCallStart{partial: partial}] = events
      assert [%ToolCall{name: "TodoWrite"}] = partial.content
    end

    test "with oauth?, CC-cased name restores caller's original casing" do
      caller_tools = [%Tool{name: "todowrite", description: "", parameters: %{}}]
      {_, state} = Decoder.new(model(), oauth?: true, tools: caller_tools)

      {_events, state} =
        Decoder.handle(state, %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "TodoWrite",
            "input" => %{}
          }
        })

      assert [%ToolCall{name: "todowrite"}] = state.message.content
    end

    test "with oauth?, unmatched name passes through unchanged" do
      {_, state} = Decoder.new(model(), oauth?: true, tools: [])

      {_events, state} =
        Decoder.handle(state, %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "Glob",
            "input" => %{}
          }
        })

      assert [%ToolCall{name: "Glob"}] = state.message.content
    end
  end

  describe "interleaved content blocks" do
    test "text block followed by tool_use in one stream" do
      # Claude's common "Let me look... <tool_use>" pattern. Previous
      # tests only covered text+text; this ensures two different block
      # types coexist in one message.
      {_, state} = Decoder.new(model())

      events = [
        %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        },
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Let me check."}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{
          "type" => "content_block_start",
          "index" => 1,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "edit",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"x"})}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{}
        }
      ]

      {_events, state} = feed(state, events)

      assert %Event.Done{reason: :tool_use, message: final} = Decoder.finalize(state)

      assert [
               %Content.Text{text: "Let me check."},
               %ToolCall{id: "toolu_1", name: "edit", arguments: %{"path" => "x"}}
             ] = final.content
    end

    test "out-of-order content_block indices still route to the right block" do
      # pi-mono uses findIndex on the content list; we use an index_map.
      # Verify index:1 arriving before index:0 doesn't break routing.
      {_, state} = Decoder.new(model())

      events = [
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "second-block"}
        },
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "first-block"}
        }
      ]

      {_events, state} = feed(state, events)

      # Content is appended in arrival order, not by Anthropic index:
      # position 0 (arrived first) has index:1's data, and vice versa.
      # `state.message.content` is reverse-ordered during streaming;
      # use `Decoder.message/1` for the forward (arrival-order) view.
      assert [
               %Content.Text{text: "second-block"},
               %Content.Text{text: "first-block"}
             ] = Decoder.message(state).content
    end
  end

  describe "tool-call persistence invariant" do
    test "finalized ToolCall struct carries no `partial_json` scratch field" do
      # Structurally enforced — ToolCall is a plain struct without that
      # field. Pin the invariant so a future change can't re-introduce
      # it without updating this test.
      {_, state} = Decoder.new(model())

      events = [
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "x",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"k":"v"})}
        },
        %{"type" => "content_block_stop", "index" => 0}
      ]

      {events_out, state} = feed(state, events)

      assert %Event.ToolCallEnd{tool_call: %ToolCall{} = tool_call} = List.last(events_out)
      refute Map.has_key?(tool_call, :partial_json)
      assert [%ToolCall{} = persisted] = Decoder.message(state).content
      refute Map.has_key?(persisted, :partial_json)
    end
  end

  describe "reverse-order content storage (opi-se9)" do
    # The decoder stores `state.message.content` reverse-ordered during
    # streaming so the open block sits at the head and every delta
    # mutates it in O(1) via `[head | rest]` instead of walking the
    # spine via `List.update_at`. These tests pin the invariants:
    #
    # - Final assembled message (post-finalize) is forward-order.
    # - Mid-stream `partial:` carried by every event is forward-order.
    # - The open block's text/thinking accumulates correctly across
    #   many deltas (binary append optimization friendly).
    # - The forward-order accessor `Decoder.message/1` matches what
    #   `Decoder.finalize/1` produces.

    test "text + thinking + tool_use blocks land in arrival order in finalize" do
      {_, state} = Decoder.new(model())

      events = [
        %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 1}}
        },
        %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "thinking"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "thinking_delta", "thinking" => "ponder"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "Let me edit"}
        },
        %{"type" => "content_block_stop", "index" => 1},
        %{
          "type" => "content_block_start",
          "index" => 2,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "t1",
            "name" => "edit",
            "input" => %{}
          }
        },
        %{
          "type" => "content_block_delta",
          "index" => 2,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"a"})}
        },
        %{"type" => "content_block_stop", "index" => 2},
        %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{}
        }
      ]

      {_events, state} = feed(state, events)

      assert %Event.Done{message: final} = Decoder.finalize(state)

      assert [
               %Content.Thinking{thinking: "ponder"},
               %Content.Text{text: "Let me edit"},
               %ToolCall{id: "t1", name: "edit", arguments: %{"path" => "a"}}
             ] = final.content

      # Decoder.message/1 matches what finalize hands out for the
      # content list (modulo Done's other metadata).
      assert Decoder.message(state).content == final.content
    end

    test "many text deltas to one block produce the right concatenated text" do
      {_, state} = Decoder.new(model())

      n = 75
      chunks = for i <- 1..n, do: "[#{i}]"
      expected_text = Enum.join(chunks, "")

      events =
        [
          %{
            "type" => "message_start",
            "message" => %{"id" => "m", "usage" => %{"input_tokens" => 1}}
          },
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}}
        ] ++
          Enum.map(chunks, fn chunk ->
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => chunk}
            }
          end) ++
          [
            %{"type" => "content_block_stop", "index" => 0},
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "end_turn"},
              "usage" => %{}
            }
          ]

      {emitted_events, state} = feed(state, events)

      # Each TextDelta carries the partial in forward order, with the
      # open block at the tail. The final TextDelta's partial.content
      # should hold the fully-assembled text in a single Text block.
      text_deltas = Enum.filter(emitted_events, &match?(%Event.TextDelta{}, &1))
      assert length(text_deltas) == n

      last_delta = List.last(text_deltas)
      assert [%Content.Text{text: text_so_far}] = last_delta.partial.content
      assert text_so_far == expected_text

      # Final message after finalize is forward-order with the right text.
      assert %Event.Done{message: final} = Decoder.finalize(state)
      assert [%Content.Text{text: ^expected_text}] = final.content
    end

    test "many text deltas mixed with a trailing tool_use keep block ordering" do
      # Stress the multi-block-with-many-deltas case: a long text
      # block followed by a tool_use. The text block ends up at
      # position 0, tool_use at position 1, in the final message.
      {_, state} = Decoder.new(model())

      n = 50
      text_chunks = for i <- 1..n, do: "x#{i}"
      expected_text = Enum.join(text_chunks, "")

      events =
        [
          %{
            "type" => "message_start",
            "message" => %{"id" => "m", "usage" => %{"input_tokens" => 1}}
          },
          %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}}
        ] ++
          Enum.map(text_chunks, fn chunk ->
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => chunk}
            }
          end) ++
          [
            %{"type" => "content_block_stop", "index" => 0},
            %{
              "type" => "content_block_start",
              "index" => 1,
              "content_block" => %{
                "type" => "tool_use",
                "id" => "t1",
                "name" => "edit",
                "input" => %{}
              }
            },
            %{
              "type" => "content_block_delta",
              "index" => 1,
              "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"x"})}
            },
            %{"type" => "content_block_stop", "index" => 1},
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "tool_use"},
              "usage" => %{}
            }
          ]

      {_events, state} = feed(state, events)

      assert %Event.Done{message: final} = Decoder.finalize(state)

      assert [
               %Content.Text{text: ^expected_text},
               %ToolCall{id: "t1", name: "edit", arguments: %{"path" => "x"}}
             ] = final.content
    end

    test "every emitted partial: holds content in forward order" do
      # Pin the contract that consumers (Loop, agent.demo, etc.) see
      # forward-ordered content on every event, regardless of the
      # decoder's internal reverse-ordered storage.
      {_, state} = Decoder.new(model())

      events = [
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "first"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "text"}},
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "second"}
        },
        %{"type" => "content_block_stop", "index" => 1}
      ]

      {emitted, _state} = feed(state, events)

      # After both blocks have been started, every event's `partial:`
      # (or its TextEnd `content`) reflects forward-order arrival.
      partials =
        emitted
        |> Enum.map(fn
          %{partial: p} -> p
          _ -> nil
        end)
        |> Enum.reject(&is_nil/1)

      # The last event in this stream is a TextEnd for index 1 — its
      # partial.content has both blocks, in arrival order.
      last_partial = List.last(partials)

      assert [
               %Content.Text{text: "first"},
               %Content.Text{text: "second"}
             ] = last_partial.content
    end

    test "out-of-order content_block_start indices preserve arrival ordering" do
      # Already covered by the earlier "out-of-order" test, but pin
      # the stronger claim: with the new reverse-order storage and
      # the open-block fast path, an out-of-order delta to the
      # NON-open (older) block still routes via the index_map and
      # falls back to the cold path correctly.
      {_, state} = Decoder.new(model())

      events = [
        %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text"}},
        %{"type" => "content_block_start", "index" => 1, "content_block" => %{"type" => "text"}},
        # Delta to the OLDER (forward position 0) block while the
        # newer one is open — exercises the cold path that translates
        # forward index to reverse index inside `update_block/3`.
        %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "OLD"}
        },
        %{
          "type" => "content_block_delta",
          "index" => 1,
          "delta" => %{"type" => "text_delta", "text" => "NEW"}
        },
        %{"type" => "content_block_stop", "index" => 0},
        %{"type" => "content_block_stop", "index" => 1}
      ]

      {_events, state} = feed(state, events)

      assert [
               %Content.Text{text: "OLD"},
               %Content.Text{text: "NEW"}
             ] = Decoder.message(state).content
    end

    test "input_json_delta accumulation across many fragments yields full args" do
      # Simulate a realistic streamed tool call where the JSON arrives
      # in many small fragments. PartialJson handles repair; we want
      # to confirm the reverse-order storage doesn't disturb the
      # accumulator (state.partial_json) or final argument map.
      {_, state} = Decoder.new(model())

      json = ~s({"path":"src/main.ex","mode":"replace","text":"defmodule M do\\nend"})
      fragments = for <<chunk::binary-size(3) <- json>>, do: chunk

      fragments =
        fragments ++
          [binary_part(json, length(fragments) * 3, byte_size(json) - length(fragments) * 3)]

      events =
        [
          %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{
              "type" => "tool_use",
              "id" => "t1",
              "name" => "edit",
              "input" => %{}
            }
          }
        ] ++
          Enum.map(fragments, fn frag ->
            %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "input_json_delta", "partial_json" => frag}
            }
          end) ++
          [
            %{"type" => "content_block_stop", "index" => 0},
            %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "tool_use"},
              "usage" => %{}
            }
          ]

      {_events, state} = feed(state, events)

      assert %Event.Done{message: final} = Decoder.finalize(state)

      assert [
               %ToolCall{
                 id: "t1",
                 name: "edit",
                 arguments: %{
                   "path" => "src/main.ex",
                   "mode" => "replace",
                   "text" => "defmodule M do\nend"
                 }
               }
             ] = final.content
    end
  end
end
