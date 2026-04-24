defmodule OctoPi.AI.Providers.OpenAI.DecoderTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.{Content, Event, Message, Model, ToolCall, Usage}
  alias OctoPi.AI.Providers.OpenAI.Decoder

  defp model(attrs \\ %{}) do
    %Model{
      id: Map.get(attrs, :id, "gpt-4o"),
      name: "GPT-4o",
      api: :openai_completions,
      provider: Map.get(attrs, :provider, :openai),
      base_url: "https://api.openai.com/v1",
      context_window: 128_000,
      max_tokens: 16_384,
      reasoning: Map.get(attrs, :reasoning, false)
    }
  end

  defp chunk(delta, opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, "chatcmpl-test"),
      "choices" => [
        %{
          "delta" => delta,
          "finish_reason" => Keyword.get(opts, :finish_reason)
        }
      ],
      "usage" => Keyword.get(opts, :usage)
    }
  end

  defp feed(state, chunks) when is_list(chunks) do
    Enum.reduce(chunks, {[], state}, fn ch, {events_acc, st} ->
      {events, st} = Decoder.handle(st, ch)
      {events_acc ++ events, st}
    end)
  end

  describe "new/1" do
    test "returns start event and initial state" do
      {start_event, state} = Decoder.new(model())

      assert %Event.Start{partial: partial} = start_event
      assert %Message.Assistant{content: [], api: :openai_completions} = partial
      assert state.model.id == "gpt-4o"
    end
  end

  describe "text streaming" do
    test "emits text_start, text_delta, text_end for simple text" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{"content" => "Hello"}),
        chunk(%{"content" => " world"}),
        chunk(%{}, finish_reason: "stop")
      ]

      {events, state} = feed(state, chunks)
      terminal = Decoder.finalize(state)

      assert [
        %Event.TextStart{content_index: 0},
        %Event.TextDelta{content_index: 0, delta: "Hello"},
        %Event.TextDelta{content_index: 0, delta: " world"},
      ] = events

      assert %Event.Done{reason: :stop, message: msg} = terminal
      assert [%Content.Text{text: "Hello world"}] = msg.content
    end

    test "ignores null and empty content deltas" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{"content" => nil}),
        chunk(%{"content" => ""}),
        chunk(%{"content" => "hi"}),
        chunk(%{}, finish_reason: "stop")
      ]

      {events, _state} = feed(state, chunks)

      text_starts = Enum.filter(events, &match?(%Event.TextStart{}, &1))
      assert length(text_starts) == 1
    end
  end

  describe "reasoning" do
    test "emits thinking events from reasoning_content field" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{"reasoning_content" => "Let me think..."}),
        chunk(%{"reasoning_content" => " more thinking"}),
        chunk(%{"content" => "Answer"}),
        chunk(%{}, finish_reason: "stop")
      ]

      {events, state} = feed(state, chunks)
      terminal = Decoder.finalize(state)

      assert [
        %Event.ThinkingStart{content_index: 0},
        %Event.ThinkingDelta{content_index: 0, delta: "Let me think..."},
        %Event.ThinkingDelta{content_index: 0, delta: " more thinking"},
        %Event.ThinkingEnd{content_index: 0, content: "Let me think... more thinking"},
        %Event.TextStart{content_index: 1},
        %Event.TextDelta{content_index: 1, delta: "Answer"},
      ] = events

      assert %Event.Done{message: msg} = terminal
      assert [%Content.Thinking{thinking: "Let me think... more thinking"}, %Content.Text{text: "Answer"}] = msg.content
    end

    test "emits thinking events from reasoning field" do
      {_start, state} = Decoder.new(model())
      {events, _state} = feed(state, [chunk(%{"reasoning" => "thought"})])

      assert [%Event.ThinkingStart{}, %Event.ThinkingDelta{delta: "thought"}] = events
    end

    test "emits thinking events from reasoning_text field" do
      {_start, state} = Decoder.new(model())
      {events, _state} = feed(state, [chunk(%{"reasoning_text" => "thought"})])

      assert [%Event.ThinkingStart{}, %Event.ThinkingDelta{delta: "thought"}] = events
    end

    test "uses first non-empty reasoning field, ignores others" do
      {_start, state} = Decoder.new(model())

      {events, _state} =
        feed(state, [
          chunk(%{"reasoning_content" => "first", "reasoning" => "second"})
        ])

      deltas = Enum.filter(events, &match?(%Event.ThinkingDelta{}, &1))
      assert length(deltas) == 1
      assert hd(deltas).delta == "first"
    end
  end

  describe "tool calls" do
    test "emits toolcall events for a single tool call" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{
          "tool_calls" => [
            %{"index" => 0, "id" => "call_abc", "function" => %{"name" => "read", "arguments" => ""}}
          ]
        }),
        chunk(%{
          "tool_calls" => [
            %{"index" => 0, "function" => %{"arguments" => "{\"path\":"}}
          ]
        }),
        chunk(%{
          "tool_calls" => [
            %{"index" => 0, "function" => %{"arguments" => "\"foo.txt\"}"}}
          ]
        }),
        chunk(%{}, finish_reason: "tool_calls")
      ]

      {events, state} = feed(state, chunks)
      terminal = Decoder.finalize(state)

      assert [
        %Event.ToolCallStart{content_index: 0},
        %Event.ToolCallDelta{content_index: 0},
        %Event.ToolCallDelta{content_index: 0},
        %Event.ToolCallDelta{content_index: 0}
      ] = events

      assert %Event.Done{reason: :tool_use, message: msg} = terminal
      [tc] = msg.content
      assert %ToolCall{id: "call_abc", name: "read", arguments: %{"path" => "foo.txt"}} = tc
    end

    test "handles multiple parallel tool calls via index" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{
          "tool_calls" => [
            %{"index" => 0, "id" => "call_1", "function" => %{"name" => "read", "arguments" => "{\"path\":\"a\"}"}}
          ]
        }),
        chunk(%{
          "tool_calls" => [
            %{"index" => 1, "id" => "call_2", "function" => %{"name" => "write", "arguments" => "{\"path\":\"b\"}"}}
          ]
        }),
        chunk(%{}, finish_reason: "tool_calls")
      ]

      {events, state} = feed(state, chunks)
      terminal = Decoder.finalize(state)

      starts = Enum.filter(events, &match?(%Event.ToolCallStart{}, &1))
      assert length(starts) == 2

      assert %Event.Done{message: msg} = terminal
      assert length(msg.content) == 2
      [tc1, tc2] = msg.content
      assert tc1.name == "read"
      assert tc2.name == "write"
    end
  end

  describe "usage parsing" do
    test "parses standard chunk.usage" do
      {_start, state} = Decoder.new(model())

      usage = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "prompt_tokens_details" => %{"cached_tokens" => 20, "cache_write_tokens" => 0},
        "completion_tokens_details" => %{"reasoning_tokens" => 0}
      }

      {_events, state} =
        feed(state, [
          chunk(%{"content" => "hi"}, usage: usage),
          chunk(%{}, finish_reason: "stop")
        ])

      terminal = Decoder.finalize(state)
      assert %Event.Done{message: msg} = terminal
      assert msg.usage.input == 80
      assert msg.usage.output == 50
      assert msg.usage.cache_read == 20
      assert msg.usage.cache_write == 0
      assert msg.usage.total_tokens == 150
    end

    test "normalizes cache_read when cache_write is positive" do
      {_start, state} = Decoder.new(model())

      usage = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "prompt_tokens_details" => %{"cached_tokens" => 80, "cache_write_tokens" => 30},
        "completion_tokens_details" => %{"reasoning_tokens" => 0}
      }

      {_events, state} = feed(state, [chunk(%{"content" => "x"}, usage: usage)])
      msg = Decoder.message(state)
      assert msg.usage.cache_read == 50
      assert msg.usage.cache_write == 30
    end

    test "adds reasoning tokens to output" do
      {_start, state} = Decoder.new(model())

      usage = %{
        "prompt_tokens" => 100,
        "completion_tokens" => 50,
        "prompt_tokens_details" => %{"cached_tokens" => 0},
        "completion_tokens_details" => %{"reasoning_tokens" => 10}
      }

      {_events, state} = feed(state, [chunk(%{"content" => "x"}, usage: usage)])
      msg = Decoder.message(state)
      assert msg.usage.output == 60
    end

    test "falls back to choice.usage (Moonshot)" do
      {_start, state} = Decoder.new(model())

      ch = %{
        "id" => "chatcmpl-test",
        "choices" => [
          %{
            "delta" => %{"content" => "hi"},
            "finish_reason" => nil,
            "usage" => %{
              "prompt_tokens" => 10,
              "completion_tokens" => 5
            }
          }
        ]
      }

      {_events, state} = feed(state, [ch])
      msg = Decoder.message(state)
      assert msg.usage.input == 10
      assert msg.usage.output == 5
    end
  end

  describe "stop reasons" do
    test "stop → :stop" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "stop")])
      assert %Event.Done{reason: :stop} = Decoder.finalize(state)
    end

    test "end → :stop" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "end")])
      assert %Event.Done{reason: :stop} = Decoder.finalize(state)
    end

    test "length → :length" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "length")])
      assert %Event.Done{reason: :length} = Decoder.finalize(state)
    end

    test "tool_calls → :tool_use" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "tool_calls")])
      assert %Event.Done{reason: :tool_use} = Decoder.finalize(state)
    end

    test "function_call → :tool_use" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "function_call")])
      assert %Event.Done{reason: :tool_use} = Decoder.finalize(state)
    end

    test "content_filter → :error with message" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "content_filter")])
      terminal = Decoder.finalize(state)
      assert %Event.Error{reason: :error, message: msg} = terminal
      assert msg.error_message =~ "content_filter"
    end

    test "unknown reason → :error" do
      {_start, state} = Decoder.new(model())
      {_, state} = feed(state, [chunk(%{}, finish_reason: "some_weird_reason")])
      terminal = Decoder.finalize(state)
      assert %Event.Error{reason: :error, message: msg} = terminal
      assert msg.error_message =~ "some_weird_reason"
    end
  end

  describe "response_id" do
    test "captures response_id from first chunk" do
      {_start, state} = Decoder.new(model())

      {_events, state} =
        feed(state, [
          chunk(%{"content" => "hi"}, id: "chatcmpl-abc123"),
          chunk(%{}, finish_reason: "stop", id: "chatcmpl-abc123")
        ])

      terminal = Decoder.finalize(state)
      assert terminal.message.response_id == "chatcmpl-abc123"
    end
  end

  describe "empty stream" do
    test "immediate finish_reason with no content" do
      {_start, state} = Decoder.new(model())
      {events, state} = feed(state, [chunk(%{}, finish_reason: "stop")])

      assert events == []
      terminal = Decoder.finalize(state)
      assert %Event.Done{reason: :stop, message: msg} = terminal
      assert msg.content == []
    end
  end

  describe "error/3" do
    test "produces error event with message" do
      {_start, state} = Decoder.new(model())
      {error_event, _state} = Decoder.error(state, "connection reset", :error)

      assert %Event.Error{reason: :error, message: msg} = error_event
      assert msg.error_message == "connection reset"
      assert msg.stop_reason == :error
    end

    test "produces aborted event" do
      {_start, state} = Decoder.new(model())
      {error_event, _state} = Decoder.error(state, "cancelled", :aborted)

      assert %Event.Error{reason: :aborted} = error_event
    end
  end

  describe "mixed content" do
    test "text then tool call finishes text block before starting tool" do
      {_start, state} = Decoder.new(model())

      chunks = [
        chunk(%{"content" => "I'll read that file."}),
        chunk(%{
          "tool_calls" => [
            %{"index" => 0, "id" => "call_1", "function" => %{"name" => "read", "arguments" => "{}"}}
          ]
        }),
        chunk(%{}, finish_reason: "tool_calls")
      ]

      {events, state} = feed(state, chunks)
      terminal = Decoder.finalize(state)

      event_types = Enum.map(events, &event_type/1)
      assert :text_end in event_types
      assert :toolcall_start in event_types

      text_end_idx = Enum.find_index(event_types, &(&1 == :text_end))
      tc_start_idx = Enum.find_index(event_types, &(&1 == :toolcall_start))
      assert text_end_idx < tc_start_idx

      assert %Event.Done{message: msg} = terminal
      assert [%Content.Text{}, %ToolCall{}] = msg.content
    end
  end

  defp event_type(%Event.TextStart{}), do: :text_start
  defp event_type(%Event.TextDelta{}), do: :text_delta
  defp event_type(%Event.TextEnd{}), do: :text_end
  defp event_type(%Event.ThinkingStart{}), do: :thinking_start
  defp event_type(%Event.ThinkingDelta{}), do: :thinking_delta
  defp event_type(%Event.ThinkingEnd{}), do: :thinking_end
  defp event_type(%Event.ToolCallStart{}), do: :toolcall_start
  defp event_type(%Event.ToolCallDelta{}), do: :toolcall_delta
  defp event_type(%Event.ToolCallEnd{}), do: :toolcall_end
  defp event_type(%Event.Done{}), do: :done
  defp event_type(%Event.Error{}), do: :error
end
