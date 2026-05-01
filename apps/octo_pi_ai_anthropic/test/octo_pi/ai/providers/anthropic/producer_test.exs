defmodule OctoPi.AI.Providers.Anthropic.ProducerTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Context
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.Anthropic.Producer
  alias OctoPi.AI.TestSupport.FakeAnthropicPlug, as: Fake
  alias OctoPi.AI.ToolCall

  def __telemetry_forward__(name, meas, meta, %{pid: pid, ref: ref}) do
    send(pid, {ref, name, meas, meta})
  end

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-key")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
    :ok
  end

  defp model do
    %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "http://test.invalid/v1",
      context_window: 200_000,
      max_tokens: 6000
    }
  end

  defp user_context do
    %Context{messages: [%Message.User{content: "hi", timestamp: 0}]}
  end

  defp start_producer(chunks, status \\ 200) do
    caller = self()

    {:ok, pid} =
      Producer.start(%{
        model: model(),
        context: user_context(),
        opts: %CallOptions{},
        caller: caller,
        req_overrides: [plug: Fake.serve(chunks, status)]
      })

    pid
  end

  # Drain everything from our mailbox tagged with the producer pid.
  # Returns events in order. Times out after 2s.
  defp collect_events(pid, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(pid, [], deadline)
  end

  defp do_collect(pid, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^pid, :event, event} -> do_collect(pid, [event | acc], deadline)
      {^pid, :done} -> Enum.reverse(acc)
    after
      remaining ->
        flunk("timed out after #{remaining}ms; collected: #{inspect(Enum.reverse(acc))}")
    end
  end

  describe "full streaming flow" do
    test "emits start, text lifecycle, and done for a simple text response" do
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{
            "id" => "msg_1",
            "usage" => %{
              "input_tokens" => 5,
              "output_tokens" => 0,
              "cache_read_input_tokens" => 0,
              "cache_creation_input_tokens" => 0
            }
          }
        }),
        Fake.sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text"}
        }),
        Fake.sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "Hello "}
        }),
        Fake.sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "world"}
        }),
        Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 3}
        }),
        Fake.sse("message_stop", %{"type" => "message_stop"})
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert [
               %Event.Start{},
               %Event.TextStart{content_index: 0},
               %Event.TextDelta{delta: "Hello "},
               %Event.TextDelta{delta: "world"},
               %Event.TextEnd{content: "Hello world"},
               %Event.Done{reason: :stop, message: final}
             ] = events

      assert %Message.Assistant{response_id: "msg_1", stop_reason: :stop} = final
    end

    test "emits tool_use events with parsed arguments" do
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        }),
        Fake.sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{
            "type" => "tool_use",
            "id" => "toolu_1",
            "name" => "edit",
            "input" => %{}
          }
        }),
        Fake.sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "input_json_delta", "partial_json" => ~s({"path":"x.md"})}
        }),
        Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "tool_use"},
          "usage" => %{}
        })
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert Enum.any?(events, &match?(%Event.ToolCallEnd{}, &1))
      assert %Event.Done{reason: :tool_use, message: msg} = List.last(events)

      assert [%ToolCall{id: "toolu_1", name: "edit", arguments: %{"path" => "x.md"}}] =
               msg.content
    end
  end

  describe "error handling" do
    test "non-2xx HTTP status surfaces as Error event" do
      body = ~s({"type":"error","error":{"message":"overloaded"}})
      pid = start_producer([body], 529)
      events = collect_events(pid)

      assert [%Event.Start{}, %Event.Error{reason: :error, message: msg}] = events
      assert msg.error_message =~ "HTTP 529"
    end

    test "SSE `event: error` raises and becomes Error event" do
      chunks = [
        "event: error\ndata: overloaded_error\n\n"
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert [%Event.Start{}, %Event.Error{reason: :error, message: msg}] = events
      assert msg.error_message =~ "Anthropic SSE error"
    end

    test "stream ending without stop_reason yields Error" do
      # No message_delta → stop_reason stays nil → finalize emits Error.
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        }),
        Fake.sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text"}
        }),
        Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0})
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert %Event.Error{reason: :error, message: msg} = List.last(events)
      assert msg.error_message =~ "stream ended"
    end
  end

  describe "lifecycle" do
    test "Producer exits cleanly after sending :done" do
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        }),
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{}
        })
      ]

      pid = start_producer(chunks)
      # Monitor before consuming so we see the DOWN regardless of whether
      # the producer terminates before or after the mailbox drain.
      ref_mon = Process.monitor(pid)

      _events = collect_events(pid)

      # :normal when we race with termination, :noproc if the process was
      # already gone when we monitored. Either means "clean shutdown".
      assert_receive {:DOWN, ^ref_mon, :process, ^pid, reason}, 500
      assert reason in [:normal, :noproc]
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler = "producer-telemetry-#{inspect(ref)}"

      events = [
        [:octo_pi_ai, :request, :start],
        [:octo_pi_ai, :request, :stop],
        [:octo_pi_ai, :request, :exception]
      ]

      :telemetry.attach_many(
        handler,
        events,
        &__MODULE__.__telemetry_forward__/4,
        %{pid: test_pid, ref: ref}
      )

      on_exit(fn -> :telemetry.detach(handler) end)
      {:ok, telemetry_ref: ref}
    end

    test "emits start then stop on a successful request", %{telemetry_ref: tref} do
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        }),
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{"output_tokens" => 2}
        })
      ]

      pid = start_producer(chunks)
      _events = collect_events(pid)

      assert_receive {^tref, [:octo_pi_ai, :request, :start], _meas, meta}
      assert meta.api == :anthropic_messages
      assert meta.model == "claude-haiku-4-5"
      assert meta.auth_type == :api_key

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], meas, meta}
      assert is_integer(meas.duration) and meas.duration > 0
      assert meas.input_tokens == 5
      assert meas.output_tokens == 2
      assert meta.api == :anthropic_messages
      assert meta.stop_reason == :stop
      assert meta.http_status == 200
    end

    test "emits stop with http_status on non-2xx response", %{telemetry_ref: tref} do
      pid = start_producer([~s({"error":"boom"})], 500)
      _events = collect_events(pid)

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], _meas, meta}
      assert meta.http_status == 500
    end

    test "emits :aborted stop_reason when the caller dies mid-stream", %{telemetry_ref: tref} do
      # Chunks with a sleep so the test has time to kill the caller while
      # the producer is receiving. Then a message_delta that would
      # normally yield :stop — but the caller's death should intercept.
      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
        }),
        {:sleep, 300},
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{}
        })
      ]

      caller = spawn(fn -> Process.sleep(:infinity) end)
      caller_mon = Process.monitor(caller)

      {:ok, _pid} =
        Producer.start(%{
          model: model(),
          context: user_context(),
          opts: %CallOptions{},
          caller: caller,
          req_overrides: [plug: Fake.serve(chunks)]
        })

      # Give the producer a moment to start the request.
      Process.sleep(50)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_mon, :process, ^caller, :killed}, 500

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], _meas, %{stop_reason: :aborted}},
                     2_000
    end
  end

  describe "utf-8 across chunk boundaries" do
    test "emoji split across HTTP chunks arrives intact in a text_delta" do
      # Build a full, valid SSE event whose JSON-encoded text contains an
      # emoji, then slice its BYTE STREAM mid-emoji across two chunks.
      # The SSE layer's line buffer holds the partial bytes until the
      # second chunk completes them.
      delta_frame =
        Fake.sse("content_block_delta", %{
          "type" => "content_block_delta",
          "index" => 0,
          "delta" => %{"type" => "text_delta", "text" => "hi🚀"}
        })

      # Find the first byte of the emoji (0xF0) and split there.
      {emoji_pos, _} = :binary.match(delta_frame, <<0xF0>>)
      <<prefix::binary-size(emoji_pos + 2), suffix::binary>> = delta_frame

      chunks = [
        Fake.sse("message_start", %{
          "type" => "message_start",
          "message" => %{"id" => "m", "usage" => %{"input_tokens" => 1}}
        }),
        Fake.sse("content_block_start", %{
          "type" => "content_block_start",
          "index" => 0,
          "content_block" => %{"type" => "text"}
        }),
        prefix,
        suffix,
        Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
        Fake.sse("message_delta", %{
          "type" => "message_delta",
          "delta" => %{"stop_reason" => "end_turn"},
          "usage" => %{}
        })
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      text =
        events
        |> Enum.filter(&match?(%Event.TextDelta{}, &1))
        |> Enum.map_join("", & &1.delta)

      assert text == "hi🚀"
    end
  end
end
