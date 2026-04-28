defmodule OctoPi.AIStreamTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.Context
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
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

  defp install_fake(chunks, status \\ 200) do
    Application.put_env(:octo_pi_ai, :req_overrides, plug: Fake.serve(chunks, status))
    on_exit(fn -> Application.delete_env(:octo_pi_ai, :req_overrides) end)
  end

  defp basic_text_stream do
    [
      Fake.sse("message_start", %{
        "type" => "message_start",
        "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
      }),
      Fake.sse("content_block_start", %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "text"}
      }),
      Fake.sse("content_block_delta", %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => "hello"}
      }),
      Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
      Fake.sse("message_delta", %{
        "type" => "message_delta",
        "delta" => %{"stop_reason" => "end_turn"},
        "usage" => %{}
      })
    ]
  end

  describe "OctoPi.AI.stream/3" do
    test "returns a lazy stream that yields canonical events" do
      install_fake(basic_text_stream())

      events =
        model()
        |> OctoPi.AI.stream(user_context())
        |> Enum.to_list()

      assert [
               %Event.Start{},
               %Event.TextStart{},
               %Event.TextDelta{delta: "hello"},
               %Event.TextEnd{content: "hello"},
               %Event.Done{reason: :stop}
             ] = events
    end

    test "Stream.take/2 halts the producer early" do
      # Long stream — we'll only take the first 3 events and verify no
      # zombie process. 20 tiny chunks of text delta.
      chunks =
        [
          Fake.sse("message_start", %{
            "type" => "message_start",
            "message" => %{"id" => "m", "usage" => %{"input_tokens" => 5}}
          }),
          Fake.sse("content_block_start", %{
            "type" => "content_block_start",
            "index" => 0,
            "content_block" => %{"type" => "text"}
          })
        ] ++
          for _ <- 1..20 do
            Fake.sse("content_block_delta", %{
              "type" => "content_block_delta",
              "index" => 0,
              "delta" => %{"type" => "text_delta", "text" => "x"}
            })
          end ++
          [
            Fake.sse("content_block_stop", %{"type" => "content_block_stop", "index" => 0}),
            Fake.sse("message_delta", %{
              "type" => "message_delta",
              "delta" => %{"stop_reason" => "end_turn"},
              "usage" => %{}
            })
          ]

      install_fake(chunks)

      taken =
        model()
        |> OctoPi.AI.stream(user_context())
        |> Enum.take(3)

      assert length(taken) == 3
      assert [%Event.Start{}, %Event.TextStart{}, %Event.TextDelta{}] = taken
    end

    test "raises on unknown api" do
      bad = %{model() | api: :not_a_real_api}

      assert_raise ArgumentError, ~r/no provider registered/, fn ->
        OctoPi.AI.stream(bad, user_context())
      end
    end
  end

  describe "live Anthropic smoke" do
    # Excluded by default (see test_helper.exs). Opt in with:
    #     ANTHROPIC_API_KEY=sk-... mix test --only integration
    @tag :integration
    @tag timeout: 60_000
    test "streams a short real response from Claude" do
      # This test hits the real Anthropic API; bypass the fake plug.
      Application.delete_env(:octo_pi_ai, :req_overrides)

      real_model = %Model{
        id: "claude-haiku-4-5",
        name: "Claude Haiku 4.5",
        api: :anthropic_messages,
        provider: :anthropic,
        base_url: "https://api.anthropic.com/v1",
        context_window: 200_000,
        max_tokens: 6000
      }

      ctx = %Context{
        messages: [
          %Message.User{
            content: "Reply with exactly the word 'pong' and nothing else.",
            timestamp: 0
          }
        ]
      }

      events =
        real_model
        |> OctoPi.AI.stream(ctx, max_tokens: 20, temperature: 0.0)
        |> Enum.to_list()

      assert %Event.Start{} = List.first(events)
      assert %Event.Done{reason: reason} = List.last(events)
      assert reason in [:stop, :length]

      text =
        events
        |> Enum.filter(&match?(%Event.TextDelta{}, &1))
        |> Enum.map_join("", & &1.delta)

      assert String.contains?(String.downcase(text), "pong")
    end
  end
end
