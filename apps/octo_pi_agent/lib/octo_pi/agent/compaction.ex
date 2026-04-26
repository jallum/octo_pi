defmodule OctoPi.Agent.Compaction do
  @moduledoc """
  Pure functions for context compaction.

  Port of pi-mono's compaction/compaction.ts. The caller (Session /
  Loop) is responsible for appending the resulting CompactionEntry to
  the SessionManager; this module only reads and summarizes.
  """

  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionEntry.CustomMessageEntry
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Context, as: AIContext
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.StreamOptions

  @default_keep_recent_tokens 8_000

  @summarization_system_prompt """
  You are summarizing a conversation to compress it. Produce a concise
  but complete summary of everything that was discussed, decided, and
  done. The summary will replace the earlier messages.
  """

  # ── Public API ───────────────────────────────────────────────────────────────

  @doc """
  Find the id of the OLDEST entry to keep (the cut point).

  Walks the branch backward, accumulating a byte-size token estimate.
  Stops when accumulated tokens exceed `keep_recent_tokens`. Returns
  the id of the first entry to keep, or `nil` if the whole session
  fits within the budget.

  Valid cut points are MessageEntry wrapping User or Assistant messages,
  or CustomMessageEntry. ToolResult entries are skipped — the cut walks
  back to the preceding Assistant message.
  """
  @spec find_cut_point(SessionManager.t(), non_neg_integer()) :: String.t() | nil
  def find_cut_point(%SessionManager{} = sm, keep_recent_tokens \\ @default_keep_recent_tokens) do
    branch = SessionManager.get_branch(sm)
    walk_backward(branch, keep_recent_tokens, 0, nil)
  end

  @doc """
  Split the branch at the cut point.

  Returns a map with:
    - `messages_to_summarize` — entries BEFORE `first_kept_entry_id`
    - `first_kept_entry_id` — id of the oldest kept entry
    - `tokens_before` — total estimated token count of the full branch

  Returns `nil` when the session fits within the budget (no compaction
  needed).
  """
  @spec prepare(SessionManager.t(), non_neg_integer()) ::
          %{
            messages_to_summarize: [OctoPi.Agent.SessionEntry.t()],
            first_kept_entry_id: String.t(),
            tokens_before: non_neg_integer()
          }
          | nil
  def prepare(%SessionManager{} = sm, keep_recent_tokens \\ @default_keep_recent_tokens) do
    case find_cut_point(sm, keep_recent_tokens) do
      nil ->
        nil

      first_kept_id ->
        branch = SessionManager.get_branch(sm)
        tokens_before = Enum.sum(Enum.map(branch, &estimate_entry_tokens/1))
        {to_summarize, _kept} = Enum.split_while(branch, &(&1.id != first_kept_id))

        %{
          messages_to_summarize: to_summarize,
          first_kept_entry_id: first_kept_id,
          tokens_before: tokens_before
        }
    end
  end

  @doc """
  Run compaction: summarize the older part of the session via the LLM
  and return the result.

  Does NOT mutate the SessionManager — the caller appends the resulting
  CompactionEntry.

  Options:
    - `:keep_recent_tokens` — token budget to keep (default #{@default_keep_recent_tokens})

  Returns `{:ok, %{summary: String.t(), first_kept_entry_id: String.t(),
  tokens_before: integer()}}` or `{:error, reason}`.
  """
  @spec compact(SessionManager.t(), module(), OctoPi.AI.Model.t(), keyword()) ::
          {:ok, %{summary: String.t(), first_kept_entry_id: String.t(), tokens_before: integer()}}
          | {:error, term()}
  def compact(%SessionManager{} = sm, transport, model, opts \\ []) do
    keep = Keyword.get(opts, :keep_recent_tokens, @default_keep_recent_tokens)

    case prepare(sm, keep) do
      nil ->
        {:error, :nothing_to_compact}

      %{messages_to_summarize: to_summarize, first_kept_entry_id: first_kept_id, tokens_before: tokens_before} ->
        case summarize(to_summarize, transport, model) do
          {:ok, summary} ->
            {:ok,
             %{
               summary: summary,
               first_kept_entry_id: first_kept_id,
               tokens_before: tokens_before
             }}

          {:error, _} = err ->
            err
        end
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Walk backward through the branch (newest-first), accumulating token estimates.
  # When the budget is exceeded, return the last valid cut-point id seen.
  defp walk_backward(branch, budget, _acc, _last_valid) do
    branch
    |> Enum.reverse()
    |> do_walk_reversed(budget, 0, nil)
  end

  defp do_walk_reversed([], _budget, _acc, _last_valid), do: nil

  defp do_walk_reversed([entry | rest], budget, acc, last_valid) do
    tokens = estimate_entry_tokens(entry)
    new_acc = acc + tokens
    new_last_valid = if valid_cut_point?(entry), do: entry.id, else: last_valid

    if new_acc >= budget do
      new_last_valid
    else
      do_walk_reversed(rest, budget, new_acc, new_last_valid)
    end
  end

  defp valid_cut_point?(%MessageEntry{message: %ToolResult{}}), do: false
  defp valid_cut_point?(%MessageEntry{message: %User{}}), do: true
  defp valid_cut_point?(%MessageEntry{message: %Assistant{}}), do: true
  defp valid_cut_point?(%CustomMessageEntry{}), do: true
  defp valid_cut_point?(_), do: false

  defp estimate_entry_tokens(%MessageEntry{message: msg}) do
    msg |> Jason.encode!() |> byte_size()
  rescue
    _ -> 100
  end

  defp estimate_entry_tokens(%CustomMessageEntry{content: content}) when is_binary(content), do: byte_size(content)

  defp estimate_entry_tokens(_), do: 0

  defp summarize(entries, transport, model) do
    conversation_text = serialize_entries(entries)

    prompt = """
    <conversation>
    #{conversation_text}
    </conversation>

    The messages above are a conversation to summarize. Create a structured context \
    checkpoint summary that another LLM will use to continue the work.
    """

    messages = [
      %User{
        content: prompt,
        timestamp: :os.system_time(:millisecond)
      }
    ]

    context = %AIContext{
      system_prompt: String.trim(@summarization_system_prompt),
      messages: messages
    }

    stream = transport.stream(model, context, %StreamOptions{})

    try do
      result =
        Enum.reduce(stream, nil, fn
          %AIEvent.Done{message: %{stop_reason: :error, error_message: err}}, _acc ->
            throw({:error, err || "summarization failed"})

          %AIEvent.Done{message: %{content: content}}, _acc ->
            content
            |> Enum.filter(&match?(%Text{}, &1))
            |> Enum.map_join("", & &1.text)

          %AIEvent.Error{message: %{error_message: err}}, _acc ->
            throw({:error, err || "summarization failed"})

          _other, acc ->
            acc
        end)

      case result do
        nil -> {:error, "no terminal event from summarization transport"}
        text -> {:ok, text}
      end
    catch
      {:error, reason} -> {:error, reason}
    end
  end

  defp serialize_entries(entries) do
    entries
    |> Enum.flat_map(&entry_to_lines/1)
    |> Enum.join("\n")
  end

  defp entry_to_lines(%MessageEntry{message: %User{content: content}}) when is_binary(content), do: ["User: #{content}"]

  defp entry_to_lines(%MessageEntry{message: %User{content: content}}) when is_list(content) do
    text =
      Enum.map_join(content, " ", fn
        %Text{text: t} -> t
        other -> inspect(other)
      end)

    ["User: #{text}"]
  end

  defp entry_to_lines(%MessageEntry{message: %Assistant{content: content}}) do
    text =
      Enum.map_join(content, " ", fn
        %Text{text: t} -> t
        other -> inspect(other)
      end)

    ["Assistant: #{text}"]
  end

  defp entry_to_lines(%MessageEntry{message: %ToolResult{tool_name: name, content: content}}) do
    text =
      Enum.map_join(content, " ", fn
        %Text{text: t} -> t
        other -> inspect(other)
      end)

    ["ToolResult[#{name}]: #{text}"]
  end

  defp entry_to_lines(%CustomMessageEntry{content: content}) when is_binary(content), do: ["User: #{content}"]

  defp entry_to_lines(%CompactionEntry{summary: summary}), do: ["[Previous summary]: #{summary}"]

  defp entry_to_lines(_), do: []
end
