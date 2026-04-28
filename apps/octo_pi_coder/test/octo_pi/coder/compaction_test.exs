defmodule OctoPi.Coder.CompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction
  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Preparation
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Compaction.Settings

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

  describe "compact/2 — split-turn parallel path" do
    # Producer that responds based on the prompt body so we can tell which
    # call (history vs. turn-prefix) is which. Detection: the turn-prefix
    # variant ends with `Prompts.turn_prefix()`; default ends with
    # `Prompts.summarize()` / `Prompts.update()`.
    defp dual_producer do
      test = self()

      fn m, ctx, opts ->
        [%User{content: [%Text{text: text}]}] = ctx.messages

        kind =
          if String.ends_with?(text, Prompts.turn_prefix()),
            do: :turn_prefix,
            else: :history

        send(test, {:producer_call, kind, m, ctx, opts})

        body =
          case kind do
            :turn_prefix -> "TURN-PREFIX-BODY"
            :history -> "HISTORY-BODY"
          end

        done_with(body)
      end
    end

    defp split_prep(overrides \\ []) do
      [
        split_turn?: true,
        turn_prefix_messages: [%User{content: "later", timestamp: 0}]
      ]
      |> Keyword.merge(overrides)
      |> prep()
    end

    test "merges history and turn-prefix summaries with the upstream separator" do
      assert {:ok, %Result{summary: summary}} =
               Compaction.compact(split_prep(), model(), producer: dual_producer())

      assert_received {:producer_call, :history, _, _, _}
      assert_received {:producer_call, :turn_prefix, _, _, _}

      assert summary ==
               "HISTORY-BODY\n\n---\n\n**Turn Context (split turn):**\n\nTURN-PREFIX-BODY"
    end

    test "empty messages_to_summarize yields the 'No prior history.' literal" do
      p = split_prep(messages_to_summarize: [])

      assert {:ok, %Result{summary: summary}} =
               Compaction.compact(p, model(), producer: dual_producer())

      refute_received {:producer_call, :history, _, _, _}
      assert_received {:producer_call, :turn_prefix, _, _, _}

      assert summary ==
               "No prior history.\n\n---\n\n**Turn Context (split turn):**\n\nTURN-PREFIX-BODY"
    end

    test "turn-prefix call uses the 0.5 × reserve budget; history uses 0.8 ×" do
      assert {:ok, _} =
               Compaction.compact(split_prep(), model(), producer: dual_producer())

      assert_received {:producer_call, :history, _, _, %{max_tokens: 800}}
      assert_received {:producer_call, :turn_prefix, _, _, %{max_tokens: 500}}
    end

    test "appends file-op blocks to the merged summary" do
      file_ops = %FileOps{read: MapSet.new(["a.ex"])}
      p = split_prep(file_ops: file_ops)

      assert {:ok, %Result{summary: summary, details: details}} =
               Compaction.compact(p, model(), producer: dual_producer())

      assert String.ends_with?(summary, "<read-files>\na.ex\n</read-files>")
      assert details == %{"readFiles" => ["a.ex"], "modifiedFiles" => []}
    end

    test "custom_instructions and previous_summary flow only into the history call" do
      p = split_prep(previous_summary: "PRIOR")

      assert {:ok, _} =
               Compaction.compact(p, model(),
                 producer: dual_producer(),
                 custom_instructions: "watch X"
               )

      assert_received {:producer_call, :history, _, hctx, _}
      [%User{content: [%Text{text: htext}]}] = hctx.messages
      assert htext =~ "<previous-summary>\nPRIOR"
      assert htext =~ "Additional focus: watch X"

      assert_received {:producer_call, :turn_prefix, _, tctx, _}
      [%User{content: [%Text{text: ttext}]}] = tctx.messages
      refute ttext =~ "previous-summary"
      refute ttext =~ "Additional focus"
    end

    test "either-side error surfaces as {:error, message}" do
      producer = fn _, ctx, _ ->
        [%User{content: [%Text{text: text}]}] = ctx.messages

        if String.ends_with?(text, Prompts.turn_prefix()),
          do: error_event("turn-prefix boom"),
          else: done_with("HISTORY-BODY")
      end

      assert {:error, "turn-prefix boom"} =
               Compaction.compact(split_prep(), model(), producer: producer)
    end
  end
end
