defmodule OctoPi.Coder.Compaction.BranchSummaryResult do
  @moduledoc """
  Result of `BranchSummarization.generate/2`. Mirrors upstream
  `BranchSummaryResult` (`branch-summarization.ts:33-39`).
  """

  @enforce_keys [:summary]
  defstruct [:summary, read_files: [], modified_files: []]

  @type t :: %__MODULE__{
          summary: String.t(),
          read_files: [String.t()],
          modified_files: [String.t()]
        }
end

defmodule OctoPi.Coder.Compaction.BranchSummarization do
  @moduledoc """
  Prepare session entries and generate summaries for branch navigation.

  ## prepare/2 — two-pass entry preparation

  1. **First pass** — scan ALL entries for pi-generated `branch_summary`
     entries (`from_hook != true`) and accumulate their
     `details.readFiles` / `details.modifiedFiles` into `file_ops`.
     This ensures cumulative file tracking even when older context
     falls outside the token budget.

  2. **Second pass** — walk newest → oldest, adding messages to the
     output list until `token_budget` is reached. Summary entries
     (`compaction`, `branch_summary`) are included even when they
     would overflow the budget if `total_tokens < 0.9 × token_budget`;
     then the walk stops.  `tool_result` messages are always skipped.

  Returns a `%BranchSummarization{}` (preparation result).

  ## generate/2 — LLM branch summarization

  Calls `prepare/2`, converts to LLM messages, builds the
  `BRANCH_SUMMARY_PROMPT`-based prompt, calls the producer, prepends
  the branch preamble, and appends `<read-files>` / `<modified-files>`
  blocks.

  Returns `{:ok, %BranchSummaryResult{}}`, `:aborted`, or
  `{:error, reason}`.

  Port of `prepareBranchEntries` + `generateBranchSummary`
  (`tmp/pi-mono/.../compaction/branch-summarization.ts:185-355`).
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.StreamOptions
  alias OctoPi.Coder.Compaction.BranchSummaryResult
  alias OctoPi.Coder.Compaction.FileOps
  alias OctoPi.Coder.Compaction.Prompts
  alias OctoPi.Coder.Compaction.Serialize
  alias OctoPi.Coder.Compaction.Tokens
  alias OctoPi.Coder.Session.BranchSummaryMessage
  alias OctoPi.Coder.Session.CompactionSummaryMessage
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.Messages

  @default_producer OctoPi.AI.Providers.Anthropic

  # ---- preparation result struct -------------------------------------------

  @enforce_keys [:messages, :file_ops, :total_tokens]
  defstruct [:messages, :file_ops, :total_tokens]

  @type t :: %__MODULE__{
          messages: [term()],
          file_ops: FileOps.t(),
          total_tokens: non_neg_integer()
        }

  # ---- prepare/2 -----------------------------------------------------------

  @doc """
  Prepare `entries` (chronological order) for branch summarization.

  `token_budget` is the maximum tokens to include; `0` means no limit.
  """
  @spec prepare([Entry.t()], non_neg_integer()) :: t()
  def prepare(entries, token_budget \\ 0) when is_list(entries) and is_integer(token_budget) do
    file_ops = first_pass(entries, FileOps.new())
    {messages, file_ops, total_tokens} = second_pass(entries, file_ops, token_budget)
    %__MODULE__{messages: messages, file_ops: file_ops, total_tokens: total_tokens}
  end

  # ---- generate/2 ----------------------------------------------------------

  @type generate_opts :: [
          model: term(),
          api_key: String.t() | nil,
          headers: map() | nil,
          reserve_tokens: pos_integer(),
          custom_instructions: String.t() | nil,
          replace_instructions: boolean(),
          producer: module() | (term(), term(), term() -> Enumerable.t())
        ]

  @doc """
  Generate a summary of `entries` (chronological order) for branch
  navigation context.

  Options:
    * `:model`               — `%OctoPi.AI.Model{}` (required)
    * `:api_key`             — provider API key
    * `:headers`             — extra request headers
    * `:reserve_tokens`      — tokens reserved for prompt + response
      (default 16 384); budget = `model.context_window - reserve_tokens`
    * `:custom_instructions` — appended to (or replaces) the base prompt
    * `:replace_instructions`— when `true`, `custom_instructions` replaces
      the base `BRANCH_SUMMARY_PROMPT` entirely (default `false`)
    * `:producer`            — injection point for tests

  Returns:
    * `{:ok, %BranchSummaryResult{}}` on success
    * `:aborted` when the stream was cancelled
    * `{:error, :no_content}` when entries produce no serializable messages
    * `{:error, reason}` on LLM error
  """
  @spec generate([Entry.t()], generate_opts()) ::
          {:ok, BranchSummaryResult.t()} | :aborted | {:error, :no_content | String.t()}
  def generate(entries, opts \\ []) when is_list(entries) do
    model = Keyword.fetch!(opts, :model)
    api_key = Keyword.get(opts, :api_key)
    headers = Keyword.get(opts, :headers)
    reserve_tokens = Keyword.get(opts, :reserve_tokens, 16_384)
    custom_instructions = Keyword.get(opts, :custom_instructions)
    replace_instructions = Keyword.get(opts, :replace_instructions, false)
    producer = Keyword.get(opts, :producer, @default_producer)

    token_budget = (model.context_window || 128_000) - reserve_tokens
    prep = prepare(entries, token_budget)

    if prep.messages == [] do
      {:error, :no_content}
    else
      llm_messages = Messages.to_llm(prep.messages)
      convo_text = Serialize.conversation(llm_messages)

      instructions = build_instructions(custom_instructions, replace_instructions)
      prompt_text = "<conversation>\n#{convo_text}\n</conversation>\n\n#{instructions}"

      user_msg = %User{
        content: [%Text{text: prompt_text}],
        timestamp: System.system_time(:millisecond)
      }

      ai_ctx = %AIContext{
        system_prompt: Prompts.system(),
        messages: [user_msg],
        tools: []
      }

      stream_opts = %StreamOptions{
        max_tokens: 2048,
        api_key: api_key,
        headers: headers
      }

      producer
      |> invoke(model, ai_ctx, stream_opts)
      |> consume(prep.file_ops)
    end
  end

  # ---- private helpers -----------------------------------------------------

  defp build_instructions(nil, _replace), do: Prompts.branch_summary()
  defp build_instructions(custom, true), do: custom

  defp build_instructions(custom, false), do: Prompts.branch_summary() <> "\n\nAdditional focus: " <> custom

  defp invoke(producer, model, ctx, opts) when is_atom(producer), do: producer.stream(model, ctx, opts)

  defp invoke(fun, model, ctx, opts) when is_function(fun, 3), do: fun.(model, ctx, opts)

  defp consume(stream, file_ops) do
    result =
      Enum.reduce_while(stream, :no_done, fn
        %Event.Done{message: %Assistant{stop_reason: :aborted}}, _acc ->
          {:halt, :aborted}

        %Event.Done{message: %Assistant{content: content}}, _acc ->
          {:halt, {:ok, extract_text(content)}}

        %Event.Error{message: %Assistant{error_message: msg}}, _acc ->
          {:halt, {:error, msg || "Summarization failed"}}

        _other, acc ->
          {:cont, acc}
      end)

    case result do
      :aborted ->
        :aborted

      {:ok, summary_text} ->
        preamble = Prompts.branch_summary_preamble()
        %{read_files: reads, modified_files: modified} = FileOps.compute_lists(file_ops)
        full_summary = preamble <> summary_text <> FileOps.format(reads, modified)
        {:ok, %BranchSummaryResult{summary: full_summary, read_files: reads, modified_files: modified}}

      {:error, reason} ->
        {:error, reason}

      :no_done ->
        {:error, "stream ended without Done"}
    end
  end

  defp extract_text(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  # ---- first pass ----------------------------------------------------------

  defp first_pass(entries, ops) do
    Enum.reduce(entries, ops, fn
      %Entry.BranchSummary{from_hook: hook, details: details}, acc
      when hook != true and is_map(details) ->
        acc
        |> merge_read_files(Map.get(details, "readFiles", []))
        |> merge_modified_files(Map.get(details, "modifiedFiles", []))

      _other, acc ->
        acc
    end)
  end

  defp merge_read_files(ops, files) when is_list(files) do
    Enum.reduce(files, ops, fn
      f, acc when is_binary(f) -> %{acc | read: MapSet.put(acc.read, f)}
      _, acc -> acc
    end)
  end

  defp merge_modified_files(ops, files) when is_list(files) do
    Enum.reduce(files, ops, fn
      f, acc when is_binary(f) -> %{acc | edited: MapSet.put(acc.edited, f)}
      _, acc -> acc
    end)
  end

  # ---- second pass ---------------------------------------------------------

  defp second_pass(entries, file_ops, token_budget) do
    entries
    |> Enum.reverse()
    |> Enum.reduce_while({[], file_ops, 0}, fn entry, {msgs, ops, total} ->
      case message_from_entry(entry) do
        nil ->
          {:cont, {msgs, ops, total}}

        msg ->
          ops = FileOps.extract(msg, ops)
          tokens = Tokens.estimate_tokens(msg)

          if token_budget > 0 and total + tokens > token_budget do
            if summary_entry?(entry) and total < token_budget * 0.9 do
              {:halt, {[msg | msgs], ops, total + tokens}}
            else
              {:halt, {msgs, ops, total}}
            end
          else
            {:cont, {[msg | msgs], ops, total + tokens}}
          end
      end
    end)
  end

  defp summary_entry?(%Entry.Compaction{}), do: true
  defp summary_entry?(%Entry.BranchSummary{}), do: true
  defp summary_entry?(_), do: false

  # ---- entry → message conversion -----------------------------------------

  defp message_from_entry(%Entry.Message{message: %{"role" => "toolResult"}}), do: nil
  defp message_from_entry(%Entry.Message{message: msg}), do: msg

  defp message_from_entry(%Entry.BranchSummary{summary: s, from_id: from_id, timestamp: ts}) do
    BranchSummaryMessage.new(s, from_id, ts || 0)
  end

  defp message_from_entry(%Entry.Compaction{summary: s, tokens_before: tb, timestamp: ts}) do
    CompactionSummaryMessage.new(s, tb || 0, ts || 0)
  end

  defp message_from_entry(_), do: nil
end
