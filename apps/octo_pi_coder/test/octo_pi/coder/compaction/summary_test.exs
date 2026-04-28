defmodule OctoPi.Coder.Compaction.SummaryTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Compaction.Summary

  defp model(reasoning? \\ false) do
    %Model{
      id: "claude-test",
      name: "Test",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://example",
      reasoning: reasoning?,
      input: [:text],
      context_window: 200_000,
      max_tokens: 8192,
      cost: nil
    }
  end

  defp done_with(text) do
    [
      %Event.Done{
        reason: :stop,
        message: %Assistant{
          api: :anthropic_messages,
          provider: :anthropic,
          model: "claude-test",
          timestamp: 0,
          stop_reason: :stop,
          content: [%Text{text: text}],
          usage: %Usage{}
        }
      }
    ]
  end

  defp error_with(msg) do
    [
      %Event.Error{
        reason: :error,
        message: %Assistant{
          api: :anthropic_messages,
          provider: :anthropic,
          model: "claude-test",
          timestamp: 0,
          stop_reason: :error,
          error_message: msg,
          content: [],
          usage: %Usage{}
        }
      }
    ]
  end

  defp recording_producer(events) do
    test = self()

    fn m, ctx, opts ->
      send(test, {:producer_call, m, ctx, opts})
      events
    end
  end

  defp messages, do: [%User{content: "hello", timestamp: 0}]

  describe "generate/4 — basic path" do
    test "wraps the conversation in <conversation> tags and uses SUMMARIZATION_PROMPT" do
      producer = recording_producer(done_with("## Goal\nx"))

      assert {:ok, "## Goal\nx"} = Summary.generate(messages(), model(), 1000, producer: producer)

      assert_received {:producer_call, _model, ctx, _opts}
      assert ctx.system_prompt == Prompts.system()
      assert [%User{content: [%Text{text: text}]}] = ctx.messages
      assert text =~ "<conversation>\n[User]: hello\n</conversation>\n\n"
      assert String.ends_with?(text, Prompts.summarize())
      refute text =~ "<previous-summary>"
    end

    test "max_tokens defaults to 0.8 × reserve_tokens" do
      producer = recording_producer(done_with(""))
      assert {:ok, _} = Summary.generate(messages(), model(), 1000, producer: producer)
      assert_received {:producer_call, _, _, opts}
      assert opts[:max_tokens] == 800
    end

    test "turn_prefix variant uses TURN_PREFIX prompt and 0.5 × reserve_tokens" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(), 1000,
                 producer: producer,
                 variant: :turn_prefix
               )

      assert_received {:producer_call, _, ctx, opts}
      assert opts[:max_tokens] == 500
      [%User{content: [%Text{text: text}]}] = ctx.messages
      assert String.ends_with?(text, Prompts.turn_prefix())
    end

    test "previous_summary switches to UPDATE prompt and wraps in <previous-summary>" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(), 1000,
                 producer: producer,
                 previous_summary: "OLD-SUMMARY-BODY"
               )

      assert_received {:producer_call, _, ctx, _}
      [%User{content: [%Text{text: text}]}] = ctx.messages
      assert text =~ "<previous-summary>\nOLD-SUMMARY-BODY\n</previous-summary>"
      assert String.ends_with?(text, Prompts.update())
    end

    test "custom_instructions append 'Additional focus: ...' to the base prompt" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(), 1000,
                 producer: producer,
                 custom_instructions: "watch for migrations"
               )

      assert_received {:producer_call, _, ctx, _}
      [%User{content: [%Text{text: text}]}] = ctx.messages
      assert text =~ Prompts.summarize() <> "\n\nAdditional focus: watch for migrations"
    end

    test "empty custom_instructions is a no-op" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(), 1000,
                 producer: producer,
                 custom_instructions: ""
               )

      assert_received {:producer_call, _, ctx, _}
      [%User{content: [%Text{text: text}]}] = ctx.messages
      refute text =~ "Additional focus:"
    end

    test "api_key and headers thread into call opts" do
      producer = recording_producer(done_with(""))
      headers = %{"x-trace" => "abc"}

      assert {:ok, _} =
               Summary.generate(messages(), model(), 1000,
                 producer: producer,
                 api_key: "sk-test",
                 headers: headers
               )

      assert_received {:producer_call, _, _, opts}
      assert opts[:api_key] == "sk-test"
      assert opts[:headers] == headers
    end

    test "concatenates text blocks in the Done assistant message" do
      events = [
        %Event.Done{
          reason: :stop,
          message: %Assistant{
            api: :anthropic_messages,
            provider: :anthropic,
            model: "claude-test",
            timestamp: 0,
            stop_reason: :stop,
            content: [%Text{text: "part 1"}, %Text{text: "part 2"}],
            usage: %Usage{}
          }
        }
      ]

      producer = fn _, _, _ -> events end
      assert {:ok, "part 1\npart 2"} = Summary.generate(messages(), model(), 1000, producer: producer)
    end

    test "no reasoning option is set when thinking_level is omitted" do
      producer = recording_producer(done_with(""))
      assert {:ok, _} = Summary.generate(messages(), model(true), 1000, producer: producer)
      assert_received {:producer_call, _, _, opts}
      assert opts[:reasoning] == nil
    end
  end

  describe "generate/4 — reasoning conditional (port of compaction-summary-reasoning.test.ts)" do
    test "uses the provided thinking level for reasoning-capable models" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(true), 2000,
                 producer: producer,
                 api_key: "test-key",
                 thinking_level: :medium
               )

      assert_received {:producer_call, _, _, opts}
      assert opts[:reasoning] == :medium
      assert opts[:api_key] == "test-key"
    end

    test "does not set reasoning when thinking is off" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(true), 2000,
                 producer: producer,
                 api_key: "test-key",
                 thinking_level: :off
               )

      assert_received {:producer_call, _, _, opts}
      assert opts[:reasoning] == nil
      assert opts[:api_key] == "test-key"
    end

    test "does not set reasoning for non-reasoning models" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Summary.generate(messages(), model(false), 2000,
                 producer: producer,
                 api_key: "test-key",
                 thinking_level: :medium
               )

      assert_received {:producer_call, _, _, opts}
      assert opts[:reasoning] == nil
      assert opts[:api_key] == "test-key"
    end
  end

  describe "generate/4 — error paths" do
    test "Event.Error from producer surfaces as {:error, message}" do
      producer = fn _, _, _ -> error_with("boom") end
      assert {:error, "boom"} = Summary.generate(messages(), model(), 1000, producer: producer)
    end

    test "Event.Error with nil message becomes 'Unknown error'" do
      events = error_with(nil)
      producer = fn _, _, _ -> events end
      assert {:error, "Unknown error"} = Summary.generate(messages(), model(), 1000, producer: producer)
    end

    test "stream that ends without Done returns {:error, ...}" do
      producer = fn _, _, _ -> [] end
      assert {:error, "stream ended without Done"} = Summary.generate(messages(), model(), 1000, producer: producer)
    end
  end
end
