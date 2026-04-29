defmodule OctoPi.AI.Providers.OpenAI.ProducerTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.{CallOptions, Context, Event, Message, Model, ToolCall}
  alias OctoPi.AI.Providers.OpenAI.Producer
  alias OctoPi.AI.TestSupport.FakeOpenAIPlug, as: Fake

  def __telemetry_forward__(name, meas, meta, %{pid: pid, ref: ref}) do
    send(pid, {ref, name, meas, meta})
  end

  defp model do
    %Model{
      id: "gpt-4o",
      name: "GPT-4o",
      api: :openai_completions,
      provider: :openai,
      base_url: "http://test.invalid/v1",
      context_window: 128_000,
      max_tokens: 16_384
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
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "Hello "}, "finish_reason" => nil}]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "world"}, "finish_reason" => nil}]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}],
          "usage" => %{
            "prompt_tokens" => 5,
            "completion_tokens" => 3,
            "prompt_tokens_details" => %{"cached_tokens" => 0},
            "completion_tokens_details" => %{"reasoning_tokens" => 0}
          }
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert [
               %Event.Start{},
               %Event.TextStart{content_index: 0},
               %Event.TextDelta{delta: "Hello "},
               %Event.TextDelta{delta: "world"},
               %Event.Done{reason: :stop, message: final}
             ] = events

      assert %Message.Assistant{response_id: "chatcmpl-test", stop_reason: :stop} = final
      assert final.usage.input == 5
      assert final.usage.output == 3
    end

    test "emits tool call events with parsed arguments" do
      chunks = [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "id" => "call_abc", "function" => %{"name" => "read", "arguments" => ""}}
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [
            %{
              "delta" => %{
                "tool_calls" => [
                  %{"index" => 0, "function" => %{"arguments" => "{\"path\":\"foo.txt\"}"}}
                ]
              },
              "finish_reason" => nil
            }
          ]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "tool_calls"}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert %Event.Done{reason: :tool_use, message: msg} = List.last(events)
      assert [%ToolCall{id: "call_abc", name: "read", arguments: %{"path" => "foo.txt"}}] = msg.content
    end

    test "handles data: [DONE] terminal gracefully" do
      chunks = [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "hi"}, "finish_reason" => nil}]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert %Event.Done{reason: :stop} = List.last(events)
    end
  end

  describe "error handling" do
    test "non-2xx HTTP status surfaces as Error event" do
      body = ~s({"error":{"message":"overloaded"}})
      pid = start_producer([body], 529)
      events = collect_events(pid)

      assert [%Event.Start{}, %Event.Error{reason: :error, message: msg}] = events
      assert msg.error_message =~ "HTTP 529"
    end

    test "stream ending without finish_reason yields Done with :stop" do
      chunks = [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "hi"}, "finish_reason" => nil}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      assert %Event.Done{reason: :stop} = List.last(events)
    end
  end

  describe "lifecycle" do
    test "Producer exits cleanly after sending :done" do
      chunks = [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => nil}]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      ref_mon = Process.monitor(pid)

      _events = collect_events(pid)

      assert_receive {:DOWN, ^ref_mon, :process, ^pid, reason}, 500
      assert reason in [:normal, :noproc]
    end
  end

  describe "telemetry" do
    setup do
      test_pid = self()
      ref = make_ref()
      handler = "openai-producer-telemetry-#{inspect(ref)}"

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
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => nil}],
          "usage" => %{"prompt_tokens" => 5, "completion_tokens" => 2}
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      _events = collect_events(pid)

      assert_receive {^tref, [:octo_pi_ai, :request, :start], meas, meta}
      assert is_integer(meas.system_time)
      assert meta.api == :openai_completions
      assert meta.model == "gpt-4o"

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], meas, meta}
      assert is_integer(meas.duration) and meas.duration > 0
      assert meas.input_tokens == 5
      assert meas.output_tokens == 2
      assert meta.api == :openai_completions
      assert meta.stop_reason == :stop
      assert meta.http_status == 200
    end

    test "emits stop with http_status on non-2xx response", %{telemetry_ref: tref} do
      pid = start_producer(["{\"error\":\"boom\"}"], 500)
      _events = collect_events(pid)

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], _meas, meta}
      assert meta.http_status == 500
    end

    test "emits :aborted stop_reason when the caller dies mid-stream", %{telemetry_ref: tref} do
      chunks = [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "start"}, "finish_reason" => nil}]
        }),
        {:sleep, 300},
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
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

      Process.sleep(50)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^caller_mon, :process, ^caller, :killed}, 500

      assert_receive {^tref, [:octo_pi_ai, :request, :stop], _meas,
                      %{stop_reason: :aborted}},
                     2_000
    end
  end

  describe "utf-8 across chunk boundaries" do
    test "emoji split across HTTP chunks arrives intact in a text_delta" do
      delta_frame =
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [
            %{
              "delta" => %{"content" => "hi\xF0\x9F\x9A\x80"},
              "finish_reason" => nil
            }
          ]
        })

      {emoji_pos, _} = :binary.match(delta_frame, <<0xF0>>)
      <<prefix::binary-size(emoji_pos + 2), suffix::binary>> = delta_frame

      chunks = [
        prefix,
        suffix,
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
      ]

      pid = start_producer(chunks)
      events = collect_events(pid)

      text =
        events
        |> Enum.filter(&match?(%Event.TextDelta{}, &1))
        |> Enum.map_join("", & &1.delta)

      assert text == "hi\xF0\x9F\x9A\x80"
    end
  end

  describe "on_payload / on_response callbacks" do
    defp simple_chunks do
      [
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{"content" => "ok"}, "finish_reason" => nil}]
        }),
        Fake.sse(%{
          "id" => "chatcmpl-test",
          "choices" => [%{"delta" => %{}, "finish_reason" => "stop"}]
        }),
        Fake.done()
      ]
    end

    test "on_payload can modify the request body" do
      test_pid = self()

      opts = %CallOptions{
        on_payload: fn body, model ->
          send(test_pid, {:payload, body, model})
          Map.put(body, "custom_field", true)
        end
      }

      caller = self()

      {:ok, pid} =
        Producer.start(%{
          model: model(),
          context: user_context(),
          opts: opts,
          caller: caller,
          req_overrides: [plug: Fake.serve(simple_chunks())]
        })

      _events = collect_events(pid)

      assert_receive {:payload, body, m}
      assert body["model"] == "gpt-4o"
      assert m.id == "gpt-4o"
    end

    test "on_response receives status and headers" do
      test_pid = self()

      opts = %CallOptions{
        on_response: fn info, model ->
          send(test_pid, {:response, info, model})
          :ok
        end
      }

      caller = self()

      {:ok, pid} =
        Producer.start(%{
          model: model(),
          context: user_context(),
          opts: opts,
          caller: caller,
          req_overrides: [plug: Fake.serve(simple_chunks())]
        })

      _events = collect_events(pid)

      assert_receive {:response, info, m}
      assert info.status == 200
      assert is_map(info.headers)
      assert m.id == "gpt-4o"
    end
  end
end
