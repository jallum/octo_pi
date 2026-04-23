defmodule OctoPi.AI.Providers.Anthropic.ProducerTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.{Context, Event, Message, Model, StreamOptions, ToolCall}
  alias OctoPi.AI.Providers.Anthropic.Producer
  alias OctoPi.AI.TestSupport.FakeAnthropicPlug, as: Fake

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
    ref = make_ref()

    {:ok, pid} =
      Producer.start(%{
        model: model(),
        context: user_context(),
        opts: %StreamOptions{},
        caller: caller,
        ref: ref,
        req_overrides: [plug: Fake.serve(chunks, status)]
      })

    {pid, ref}
  end

  # Drain everything from our mailbox tagged with the producer's ref.
  # Returns events in order. Times out after 2s.
  defp collect_events(ref, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_collect(ref, [], deadline)
  end

  defp do_collect(ref, acc, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^ref, :event, event} -> do_collect(ref, [event | acc], deadline)
      {^ref, :done} -> Enum.reverse(acc)
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

      {_pid, ref} = start_producer(chunks)
      events = collect_events(ref)

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

      {_pid, ref} = start_producer(chunks)
      events = collect_events(ref)

      assert Enum.find(events, &match?(%Event.ToolCallEnd{}, &1))
      assert %Event.Done{reason: :tool_use, message: msg} = List.last(events)

      assert [%ToolCall{id: "toolu_1", name: "edit", arguments: %{"path" => "x.md"}}] =
               msg.content
    end
  end

  describe "error handling" do
    test "non-2xx HTTP status surfaces as Error event" do
      body = ~s({"type":"error","error":{"message":"overloaded"}})
      {_pid, ref} = start_producer([body], 529)
      events = collect_events(ref)

      assert [%Event.Start{}, %Event.Error{reason: :error, message: msg}] = events
      assert msg.error_message =~ "HTTP 529"
    end

    test "SSE `event: error` raises and becomes Error event" do
      chunks = [
        "event: error\ndata: overloaded_error\n\n"
      ]

      {_pid, ref} = start_producer(chunks)
      events = collect_events(ref)

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

      {_pid, ref} = start_producer(chunks)
      events = collect_events(ref)

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

      {pid, ref} = start_producer(chunks)
      # Monitor before consuming so we see the DOWN regardless of whether
      # the producer terminates before or after the mailbox drain.
      ref_mon = Process.monitor(pid)

      _events = collect_events(ref)

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
        [:octo_pi_ai, :anthropic, :request, :start],
        [:octo_pi_ai, :anthropic, :request, :stop],
        [:octo_pi_ai, :anthropic, :request, :exception]
      ]

      :telemetry.attach_many(
        handler,
        events,
        fn name, meas, meta, _ -> send(test_pid, {ref, name, meas, meta}) end,
        nil
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

      {_pid, ref} = start_producer(chunks)
      _events = collect_events(ref)

      assert_receive {^tref, [:octo_pi_ai, :anthropic, :request, :start], meas, meta}
      assert is_integer(meas.system_time)
      assert meta.model == "claude-haiku-4-5"
      assert meta.auth_type == :api_key

      assert_receive {^tref, [:octo_pi_ai, :anthropic, :request, :stop], meas, meta}
      assert is_integer(meas.duration) and meas.duration > 0
      assert meas.input_tokens == 5
      assert meas.output_tokens == 2
      assert meta.stop_reason == :stop
      assert meta.http_status == 200
    end

    test "emits stop with http_status on non-2xx response", %{telemetry_ref: tref} do
      {_pid, ref} = start_producer(["{\"error\":\"boom\"}"], 500)
      _events = collect_events(ref)

      assert_receive {^tref, [:octo_pi_ai, :anthropic, :request, :stop], _meas, meta}
      assert meta.http_status == 500
    end
  end
end
