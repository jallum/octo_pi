defmodule OctoPi.Coder.CompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.{Assistant, User}
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction
  alias OctoPi.Coder.Compaction.{FileOps, Preparation, Result, Settings}

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

  defp error_event(msg) do
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

  defp prep(overrides \\ []) do
    base = %Preparation{
      first_kept_entry_id: "kept-1",
      messages_to_summarize: [%User{content: "hello", timestamp: 0}],
      turn_prefix_messages: [],
      split_turn?: false,
      tokens_before: 12_345,
      previous_summary: nil,
      file_ops: %FileOps{},
      settings: %Settings{reserve_tokens: 1000}
    }

    Enum.reduce(overrides, base, fn {k, v}, acc -> Map.put(acc, k, v) end)
  end

  describe "compact/2 — single-pass path" do
    test "returns Result with summary, first_kept_entry_id, tokens_before from preparation" do
      producer = recording_producer(done_with("SUMMARY-BODY"))

      assert {:ok, %Result{} = res} =
               Compaction.compact(prep(), model(), producer: producer)

      assert res.summary == "SUMMARY-BODY"
      assert res.first_kept_entry_id == "kept-1"
      assert res.tokens_before == 12_345
      assert res.details == %{"readFiles" => [], "modifiedFiles" => []}
    end

    test "appends <read-files> and <modified-files> blocks to summary" do
      producer = recording_producer(done_with("BODY"))

      file_ops = %FileOps{
        read: MapSet.new(["a.ex", "b.ex"]),
        edited: MapSet.new(["c.ex"]),
        written: MapSet.new(["d.ex"])
      }

      assert {:ok, %Result{summary: summary, details: details}} =
               Compaction.compact(prep(file_ops: file_ops), model(), producer: producer)

      assert summary ==
               "BODY\n\n<read-files>\na.ex\nb.ex\n</read-files>\n\n" <>
                 "<modified-files>\nc.ex\nd.ex\n</modified-files>"

      assert details == %{
               "readFiles" => ["a.ex", "b.ex"],
               "modifiedFiles" => ["c.ex", "d.ex"]
             }
    end

    test "no file blocks appended when both lists empty" do
      producer = recording_producer(done_with("BODY"))

      assert {:ok, %Result{summary: "BODY"}} =
               Compaction.compact(prep(), model(), producer: producer)
    end

    test "passes reserve_tokens from preparation settings to Summary" do
      producer = recording_producer(done_with(""))
      p = prep(settings: %Settings{reserve_tokens: 2000})

      assert {:ok, _} = Compaction.compact(p, model(), producer: producer)
      assert_received {:producer_call, _, _, %{max_tokens: 1600}}
    end

    test "threads previous_summary into Summary.generate" do
      producer = recording_producer(done_with(""))
      p = prep(previous_summary: "PRIOR")

      assert {:ok, _} = Compaction.compact(p, model(), producer: producer)
      assert_received {:producer_call, _, ctx, _}
      [%User{content: [%Text{text: text}]}] = ctx.messages
      assert text =~ "<previous-summary>\nPRIOR\n</previous-summary>"
    end

    test "threads custom_instructions into Summary.generate" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Compaction.compact(prep(), model(),
                 producer: producer,
                 custom_instructions: "watch migrations"
               )

      assert_received {:producer_call, _, ctx, _}
      [%User{content: [%Text{text: text}]}] = ctx.messages
      assert text =~ "Additional focus: watch migrations"
    end

    test "threads thinking_level into reasoning" do
      producer = recording_producer(done_with(""))

      assert {:ok, _} =
               Compaction.compact(prep(), model(true),
                 producer: producer,
                 thinking_level: :high
               )

      assert_received {:producer_call, _, _, %{reasoning: :high}}
    end

    test "threads api_key and headers into StreamOptions" do
      producer = recording_producer(done_with(""))
      headers = %{"x-trace" => "z"}

      assert {:ok, _} =
               Compaction.compact(prep(), model(),
                 producer: producer,
                 api_key: "sk-test",
                 headers: headers
               )

      assert_received {:producer_call, _, _, opts}
      assert opts.api_key == "sk-test"
      assert opts.headers == headers
    end

    test "split_turn? with empty turn_prefix_messages still uses single-pass" do
      producer = recording_producer(done_with("BODY"))
      p = prep(split_turn?: true, turn_prefix_messages: [])

      assert {:ok, %Result{summary: "BODY"}} =
               Compaction.compact(p, model(), producer: producer)
    end

    test "Summary error surfaces as {:error, message}" do
      producer = fn _, _, _ -> error_event("boom") end

      assert {:error, "boom"} =
               Compaction.compact(prep(), model(), producer: producer)
    end
  end
end
