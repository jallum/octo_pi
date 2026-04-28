defmodule OctoPi.Coder.Compaction.BranchSummarizationTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.BranchSummarization
  alias OctoPi.Coder.Compaction.BranchSummaryResult
  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Entry

  # ---- helpers -------------------------------------------------------------

  defp user_msg(text, id \\ nil) do
    %Entry.Message{
      id: id || "m-#{text}",
      parent_id: nil,
      timestamp: "2026-01-01T00:00:00Z",
      message: %{"role" => "user", "content" => text}
    }
  end

  defp tool_result_msg(id \\ "tr") do
    %Entry.Message{
      id: id,
      parent_id: nil,
      timestamp: "2026-01-01T00:00:00Z",
      message: %{"role" => "toolResult", "content" => "result"}
    }
  end

  defp branch_summary_entry(opts) do
    details = Keyword.get(opts, :details)

    %Entry.BranchSummary{
      id: Keyword.get(opts, :id, "bs-1"),
      parent_id: nil,
      timestamp: "2026-01-01T00:00:00Z",
      summary: Keyword.get(opts, :summary, "branch summary"),
      from_id: Keyword.get(opts, :from_id, "root"),
      from_hook: Keyword.get(opts, :from_hook, nil),
      details: details
    }
  end

  defp compaction_entry(opts) do
    %Entry.Compaction{
      id: Keyword.get(opts, :id, "cmp-1"),
      parent_id: nil,
      timestamp: "2026-01-01T00:00:00Z",
      summary: Keyword.get(opts, :summary, "compacted context"),
      first_kept_entry_id: "m-1",
      tokens_before: Keyword.get(opts, :tokens_before, 100)
    }
  end

  # ---- basic results -------------------------------------------------------

  describe "prepare/2 — basic" do
    test "empty entries returns empty result" do
      result = BranchSummarization.prepare([])
      assert result.messages == []
      assert result.total_tokens == 0
    end

    test "entries within budget are all included in chronological order" do
      entries = [user_msg("alpha"), user_msg("beta"), user_msg("gamma")]
      result = BranchSummarization.prepare(entries)
      contents = Enum.map(result.messages, &Map.get(&1, "content"))
      assert contents == ["alpha", "beta", "gamma"]
    end

    test "toolResult entries are excluded from messages" do
      entries = [user_msg("hi"), tool_result_msg(), user_msg("bye")]
      result = BranchSummarization.prepare(entries)
      # only the two user messages
      assert length(result.messages) == 2
      refute Enum.any?(result.messages, fn m -> Map.get(m, "role") == "toolResult" end)
    end

    test "compaction entries produce CompactionSummaryMessage" do
      entries = [compaction_entry(summary: "old context", tokens_before: 500)]
      result = BranchSummarization.prepare(entries)
      assert [%CompactionSummaryMessage{summary: "old context", tokens_before: 500}] = result.messages
    end

    test "branch_summary entries produce BranchSummaryMessage" do
      entries = [branch_summary_entry(summary: "branch explored", from_id: "root")]
      result = BranchSummarization.prepare(entries)
      assert [%BranchSummaryMessage{summary: "branch explored", from_id: "root"}] = result.messages
    end

    test "zero token_budget means no limit" do
      long = String.duplicate("x", 10_000)
      entries = Enum.map(1..10, fn i -> user_msg("#{long}#{i}") end)
      result = BranchSummarization.prepare(entries, 0)
      assert length(result.messages) == 10
    end
  end

  # ---- file ops first pass -------------------------------------------------

  describe "prepare/2 — cumulative file ops from nested summaries" do
    test "file ops from all branch_summary entries are collected (first pass)" do
      e1 =
        branch_summary_entry(
          id: "bs-1",
          details: %{"readFiles" => ["a.txt", "b.txt"], "modifiedFiles" => ["c.txt"]}
        )

      e2 = user_msg("middle")

      e3 =
        branch_summary_entry(
          id: "bs-2",
          details: %{"readFiles" => ["d.txt"], "modifiedFiles" => ["e.txt"]}
        )

      result = BranchSummarization.prepare([e1, e2, e3])
      %{read_files: reads, modified_files: modified} = FileOps.compute_lists(result.file_ops)

      # Both summaries' files are present (a.txt/d.txt are read-only; c.txt/e.txt modified)
      assert "a.txt" in reads
      assert "b.txt" in reads
      assert "d.txt" in reads
      assert "c.txt" in modified
      assert "e.txt" in modified
    end

    test "files from branch_summary entries outside token budget are still in file_ops" do
      # Three entries; budget allows only the last one (smallest)
      large = String.duplicate("x", 4_000)

      e1 =
        branch_summary_entry(id: "bs-1", summary: large, details: %{"readFiles" => ["old.txt"], "modifiedFiles" => []})

      e2 = "a" |> String.duplicate(4_000) |> user_msg()
      e3 = user_msg("tiny")

      # Budget: ~1 token (only "tiny" fits)
      result = BranchSummarization.prepare([e1, e2, e3], 5)

      # "old.txt" came from e1 which was cut by the budget, but first pass captured it
      %{read_files: reads} = FileOps.compute_lists(result.file_ops)
      assert "old.txt" in reads
    end

    test "from_hook: true branch summaries are excluded from file ops first pass" do
      hook_entry =
        branch_summary_entry(
          id: "bs-hook",
          from_hook: true,
          details: %{"readFiles" => ["secret.txt"], "modifiedFiles" => ["hidden.txt"]}
        )

      result = BranchSummarization.prepare([hook_entry])
      %{read_files: reads, modified_files: modified} = FileOps.compute_lists(result.file_ops)
      refute "secret.txt" in reads
      refute "hidden.txt" in modified
    end

    test "branch_summary with nil details is silently skipped in first pass" do
      entry = branch_summary_entry(id: "bs-nil", details: nil)
      result = BranchSummarization.prepare([entry])
      # No crash; messages contains the BranchSummaryMessage, file ops empty
      assert [%BranchSummaryMessage{}] = result.messages
    end

    test "read files that are also modified are moved to modified_files by compute_lists" do
      e1 =
        branch_summary_entry(details: %{"readFiles" => ["x.txt"], "modifiedFiles" => ["x.txt", "y.txt"]})

      result = BranchSummarization.prepare([e1])
      %{read_files: reads, modified_files: modified} = FileOps.compute_lists(result.file_ops)
      assert "x.txt" in modified
      assert "y.txt" in modified
      refute "x.txt" in reads
    end
  end

  # ---- token budget overflow -----------------------------------------------

  describe "prepare/2 — token budget" do
    test "messages newest-first are included until budget is exhausted" do
      # Each content is 40 chars → ~10 tokens per message
      msgs = Enum.map(1..5, fn i -> user_msg(String.duplicate("#{i}", 40)) end)
      # Budget: 25 tokens → fits messages 5 and 4 (20 tokens), not 3
      result = BranchSummarization.prepare(msgs, 25)
      contents = Enum.map(result.messages, &Map.get(&1, "content"))
      assert length(result.messages) == 2
      # Chronological order: msg4 then msg5
      assert hd(contents) =~ "4"
    end

    test "summary entry is included when total < 90% of budget (even if over)" do
      # Budget: 100 tokens
      # msgs: two user msgs of 40 tokens each = 80 total
      # summary: 30 tokens → would overflow to 110, but 80 < 90 → include
      # 160 bytes / 4 = 40 tokens
      forty = String.duplicate("a", 160)
      # 120 bytes / 4 = 30 tokens
      thirty = String.duplicate("b", 120)

      bs =
        branch_summary_entry(id: "bs-sum", summary: thirty, details: nil)

      entries = [bs, user_msg(forty, "m1"), user_msg(forty, "m2")]
      # Newest-first: m2(40), m1(40), bs(30) → 80 before bs; 80 < 90 → include bs
      result = BranchSummarization.prepare(entries, 100)
      assert length(result.messages) == 3
      assert Enum.any?(result.messages, &match?(%BranchSummaryMessage{}, &1))
    end

    test "summary entry is excluded when total >= 90% of budget" do
      # Budget: 100; total before summary = 95 → 95 >= 90 → do not include
      # 95 tokens from previous msgs: one user msg of 380 chars = 95 tokens
      ninety_five = String.duplicate("a", 380)
      ten = String.duplicate("b", 40)

      bs = branch_summary_entry(id: "bs-sum", summary: ten, details: nil)
      entries = [bs, user_msg(ninety_five, "m1")]

      # Newest-first: m1(95), bs(10 → overflow, total=95 not < 90) → bs excluded
      result = BranchSummarization.prepare(entries, 100)
      assert length(result.messages) == 1
      refute Enum.any?(result.messages, &match?(%BranchSummaryMessage{}, &1))
    end

    test "no budget limit (0) — all messages included regardless of size" do
      huge = String.duplicate("x", 100_000)
      entries = Enum.map(1..5, fn _i -> user_msg(huge) end)
      result = BranchSummarization.prepare(entries, 0)
      assert length(result.messages) == 5
    end

    test "total_tokens reflects only included messages" do
      forty = String.duplicate("a", 160)
      msgs = [user_msg(forty, "m1"), user_msg(forty, "m2"), user_msg(forty, "m3")]
      # Budget: 90 → includes m3(40) + m2(40) = 80, m1 would make 120 > 90
      result = BranchSummarization.prepare(msgs, 90)
      assert result.total_tokens == 80
    end
  end

  # ---- generate/2 helpers --------------------------------------------------

  defp test_model do
    %Model{
      id: "test-model",
      name: "Test Model",
      api: :anthropic,
      provider: :anthropic,
      base_url: "https://api.anthropic.com",
      context_window: 200_000,
      max_tokens: 8192
    }
  end

  defp base_assistant(fields) do
    struct!(
      Assistant,
      Keyword.merge([api: :anthropic, provider: :anthropic, model: "claude-3", timestamp: 0, usage: %Usage{}], fields)
    )
  end

  defp done_producer(summary_text) do
    msg = base_assistant(content: [%Text{text: summary_text}], stop_reason: :end_turn)
    fn _model, _ctx, _opts -> [%AIEvent.Done{reason: :stop, message: msg}] end
  end

  defp aborted_producer do
    msg = base_assistant(content: [], stop_reason: :aborted)
    fn _model, _ctx, _opts -> [%AIEvent.Done{reason: :stop, message: msg}] end
  end

  defp error_producer(reason) do
    msg = base_assistant(content: [], stop_reason: :error, error_message: reason)
    fn _model, _ctx, _opts -> [%AIEvent.Error{reason: :error, message: msg}] end
  end

  defp capturing_producer(pid) do
    fn model, ctx, opts ->
      send(pid, {:producer_called, %{model: model, ctx: ctx, opts: opts}})
      msg = base_assistant(content: [%Text{text: "captured summary"}], stop_reason: :end_turn)
      [%AIEvent.Done{reason: :stop, message: msg}]
    end
  end

  # ---- generate/2 — basic --------------------------------------------------

  describe "generate/2 — basic" do
    test "returns :no_content error when entries produce no messages" do
      # Only toolResult entries → prepare returns empty messages
      entries = [tool_result_msg("tr1"), tool_result_msg("tr2")]
      result = BranchSummarization.generate(entries, model: test_model(), producer: done_producer("x"))
      assert result == {:error, :no_content}
    end

    test "returns {:ok, BranchSummaryResult} on success" do
      entries = [user_msg("hello world")]
      {:ok, result} = BranchSummarization.generate(entries, model: test_model(), producer: done_producer("The summary"))
      assert %BranchSummaryResult{} = result
    end

    test "summary is prefixed with the branch preamble" do
      entries = [user_msg("did some work")]
      {:ok, result} = BranchSummarization.generate(entries, model: test_model(), producer: done_producer("body text"))
      preamble = Prompts.branch_summary_preamble()
      assert String.starts_with?(result.summary, preamble)
    end

    test "summary body follows the preamble" do
      entries = [user_msg("did some work")]
      {:ok, result} = BranchSummarization.generate(entries, model: test_model(), producer: done_producer("body text"))
      preamble = Prompts.branch_summary_preamble()
      assert result.summary == preamble <> "body text"
    end

    test "returns :aborted when stream signals abort" do
      entries = [user_msg("something")]
      result = BranchSummarization.generate(entries, model: test_model(), producer: aborted_producer())
      assert result == :aborted
    end

    test "returns {:error, reason} on stream error" do
      entries = [user_msg("something")]
      result = BranchSummarization.generate(entries, model: test_model(), producer: error_producer("LLM down"))
      assert result == {:error, "LLM down"}
    end

    test "returns {:error, fallback} when error message is nil" do
      entries = [user_msg("something")]
      result = BranchSummarization.generate(entries, model: test_model(), producer: error_producer(nil))
      assert {:error, msg} = result
      assert is_binary(msg)
    end
  end

  # ---- generate/2 — prompt construction ------------------------------------

  describe "generate/2 — prompt construction" do
    test "prompt sent to producer contains <conversation> tags" do
      entries = [user_msg("a task")]
      producer = capturing_producer(self())
      BranchSummarization.generate(entries, model: test_model(), producer: producer)
      assert_received {:producer_called, %{ctx: ctx}}
      [user_message] = ctx.messages
      [%Text{text: prompt}] = user_message.content
      assert prompt =~ "<conversation>"
      assert prompt =~ "</conversation>"
    end

    test "prompt includes BRANCH_SUMMARY_PROMPT by default" do
      entries = [user_msg("a task")]
      producer = capturing_producer(self())
      BranchSummarization.generate(entries, model: test_model(), producer: producer)
      assert_received {:producer_called, %{ctx: ctx}}
      [user_message] = ctx.messages
      [%Text{text: prompt}] = user_message.content
      assert prompt =~ Prompts.branch_summary()
    end

    test "custom_instructions is appended when replace_instructions is false" do
      entries = [user_msg("a task")]
      producer = capturing_producer(self())

      BranchSummarization.generate(entries,
        model: test_model(),
        producer: producer,
        custom_instructions: "Focus on auth changes",
        replace_instructions: false
      )

      assert_received {:producer_called, %{ctx: ctx}}
      [user_message] = ctx.messages
      [%Text{text: prompt}] = user_message.content
      assert prompt =~ Prompts.branch_summary()
      assert prompt =~ "Focus on auth changes"
    end

    test "custom_instructions replaces base prompt when replace_instructions is true" do
      entries = [user_msg("a task")]
      producer = capturing_producer(self())

      BranchSummarization.generate(entries,
        model: test_model(),
        producer: producer,
        custom_instructions: "Custom only",
        replace_instructions: true
      )

      assert_received {:producer_called, %{ctx: ctx}}
      [user_message] = ctx.messages
      [%Text{text: prompt}] = user_message.content
      refute prompt =~ Prompts.branch_summary()
      assert prompt =~ "Custom only"
    end
  end

  # ---- generate/2 — file ops block assembly --------------------------------

  describe "generate/2 — file ops block assembly" do
    test "read_files and modified_files are returned in the result" do
      entry = branch_summary_entry(details: %{"readFiles" => ["a.txt"], "modifiedFiles" => ["b.txt"]})
      {:ok, result} = BranchSummarization.generate([entry], model: test_model(), producer: done_producer("summary"))
      assert "a.txt" in result.read_files
      assert "b.txt" in result.modified_files
    end

    test "summary contains read-files XML block when reads exist" do
      entry = branch_summary_entry(details: %{"readFiles" => ["readme.md"], "modifiedFiles" => []})
      {:ok, result} = BranchSummarization.generate([entry], model: test_model(), producer: done_producer("s"))
      assert result.summary =~ "readme.md"
    end

    test "modified_files are excluded from read_files in result" do
      entry =
        branch_summary_entry(details: %{"readFiles" => ["shared.ex"], "modifiedFiles" => ["shared.ex", "other.ex"]})

      {:ok, result} = BranchSummarization.generate([entry], model: test_model(), producer: done_producer("s"))
      assert "shared.ex" in result.modified_files
      refute "shared.ex" in result.read_files
    end

    test "empty file ops produce no XML blocks in summary" do
      entries = [user_msg("plain message")]
      {:ok, result} = BranchSummarization.generate(entries, model: test_model(), producer: done_producer("body"))
      preamble = Prompts.branch_summary_preamble()
      assert result.summary == preamble <> "body"
    end
  end
end
