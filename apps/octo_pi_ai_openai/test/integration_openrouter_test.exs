defmodule OctoPi.AI.Providers.OpenAI.IntegrationOpenRouterTest do
  @moduledoc """
  Live API integration tests against OpenRouter via the OpenAI Completions
  provider. Requires OPENROUTER_API_KEY. Run with:

      mix test apps/octo_pi_ai_openai/test/integration_openrouter_test.exs --include integration
  """
  use ExUnit.Case

  alias OctoPi.AI
  alias OctoPi.AI.{Content, Context, Event, Message, Model, Tool, ToolCall}

  @moduletag :integration

  defp model(overrides \\ %{}) do
    %Model{
      id: Map.get(overrides, :id, "qwen/qwen3.6-flash"),
      name: "Qwen3.6 Flash via OpenRouter",
      api: :openai_completions,
      provider: :openrouter,
      base_url: "https://openrouter.ai/api/v1",
      context_window: 200_000,
      max_tokens: 8_192
    }
  end

  defp opts do
    [
      api_key: System.get_env("OPENROUTER_API_KEY"),
      max_tokens: 2048,
      temperature: 0.0
    ]
  end

  defp stream_to_list(model, context, opts) do
    model
    |> AI.stream(context, opts)
    |> Enum.to_list()
  end

  describe "basic streaming" do
    test "streams a text response with start and done events" do
      ctx = %Context{
        system_prompt: "Reply with exactly one word.",
        messages: [%Message.User{content: "Say hello.", timestamp: 0}]
      }

      events = stream_to_list(model(), ctx, opts())

      assert %Event.Start{} = hd(events)
      assert %Event.Done{reason: :stop, message: msg} = List.last(events)
      assert msg.response_id != nil
      assert msg.stop_reason == :stop

      text =
        msg.content
        |> Enum.filter(&match?(%Content.Text{}, &1))
        |> Enum.map_join("", & &1.text)

      assert String.length(text) > 0
    end
  end

  describe "usage / tokens" do
    test "reports usage in final message" do
      ctx = %Context{
        messages: [%Message.User{content: "Say hi", timestamp: 0}]
      }

      events = stream_to_list(model(), ctx, opts())
      %Event.Done{message: msg} = List.last(events)

      assert msg.usage.input > 0
      assert msg.usage.output > 0
      assert msg.usage.total_tokens > 0
    end
  end

  describe "tool calls" do
    test "invokes a tool and returns tool_use stop reason" do
      tools = [
        %Tool{
          name: "get_weather",
          description: "Get the current weather for a city",
          parameters: %{
            "type" => "object",
            "properties" => %{
              "city" => %{"type" => "string", "description" => "City name"}
            },
            "required" => ["city"]
          }
        }
      ]

      ctx = %Context{
        system_prompt: "Always use the get_weather tool when asked about weather.",
        messages: [%Message.User{content: "What's the weather in Tokyo?", timestamp: 0}],
        tools: tools
      }

      events = stream_to_list(model(), ctx, opts())
      %Event.Done{reason: reason, message: msg} = List.last(events)

      assert reason == :tool_use

      tool_calls = Enum.filter(msg.content, &match?(%ToolCall{}, &1))
      assert tool_calls != []

      [tc | _] = tool_calls
      assert tc.name == "get_weather"
      assert is_map(tc.arguments)
      assert tc.arguments["city"] != nil
    end
  end

  describe "abort / cancellation" do
    test "halting the stream mid-flight does not crash" do
      ctx = %Context{
        system_prompt: "Write a long essay about the history of computing.",
        messages: [%Message.User{content: "Go ahead.", timestamp: 0}]
      }

      events =
        model()
        |> AI.stream(ctx, opts())
        |> Enum.take(3)

      assert length(events) == 3
      assert %Event.Start{} = hd(events)
    end
  end
end
