defmodule OctoPi.Agent.SessionManager do
  @moduledoc """
  Pure data structure that stores all session history as a tree of typed entries.

  Each entry has an `id` and `parent_id` forming a linked list from the root
  (parent_id nil) to the current `leaf_id`. The "current conversation" is
  always the path from root to leaf — branching moves the leaf to an earlier
  entry, letting new entries diverge without touching history.

  Port of pi-mono's SessionManager:
  tmp/pi-mono/packages/coding-agent/src/core/session-manager.ts
  """

  alias OctoPi.Agent.Message
  alias OctoPi.Agent.SessionEntry
  alias OctoPi.Agent.SessionEntry.BranchSummaryEntry
  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionEntry.CustomEntry
  alias OctoPi.Agent.SessionEntry.CustomMessageEntry
  alias OctoPi.Agent.SessionEntry.LabelEntry
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionEntry.ModelChangeEntry
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User

  @type t :: %__MODULE__{
          entries: [SessionEntry.t()],
          by_id: %{String.t() => SessionEntry.t()},
          leaf_id: String.t() | nil,
          session_file: String.t() | nil,
          flushed?: boolean()
        }

  defstruct entries: [], by_id: %{}, leaf_id: nil, session_file: nil, flushed?: false

  # ── Construction ─────────────────────────────────────────────────────────────

  @doc "Create an empty SessionManager."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Create a SessionManager, optionally seeded with a pre-existing entry list.

  Options:
    - `initial_entries` — oldest-first list of `SessionEntry.t()` to seed from.
      `by_id` and `leaf_id` are derived from the list.
    - `session_file` — path to a JSONL file for persistence. The file is NOT
      created until the first `%Assistant{}` message is appended.
  """
  @spec new(keyword()) :: t()
  def new(opts) when is_list(opts) do
    session_file = Keyword.get(opts, :session_file)

    case Keyword.get(opts, :initial_entries, []) do
      [] ->
        %__MODULE__{session_file: session_file}

      entries ->
        by_id = Map.new(entries, &{&1.id, &1})
        leaf_id = List.last(entries).id
        %__MODULE__{entries: entries, by_id: by_id, leaf_id: leaf_id, session_file: session_file}
    end
  end

  @doc """
  Load a SessionManager from a JSONL file.

  Each non-empty line must be a JSON-encoded entry map with a `"type"` field.
  Returns `{:ok, t()}` or `{:error, reason}`.
  """
  @spec new_from_file(String.t()) :: {:ok, t()} | {:error, term()}
  def new_from_file(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path) do
      entries =
        contents
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> Jason.decode!() |> SessionEntry.from_json()))

      sm = new(initial_entries: entries, session_file: path)
      {:ok, %{sm | flushed?: true}}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ── Append operations ────────────────────────────────────────────────────────

  @doc "Append a User | Assistant | ToolResult message as a MessageEntry."
  @spec append_message(t(), Message.t()) :: t()
  def append_message(%__MODULE__{} = sm, message) do
    entry = %MessageEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      message: message
    }

    append_entry(sm, entry)
  end

  @doc """
  Append a CompactionEntry recording a context compaction.

  Options:
    - `details` — opaque metadata (default nil)
    - `from_hook` — true when summary came from an extension (default false)
  """
  @spec append_compaction(t(), String.t(), String.t(), non_neg_integer(), keyword()) :: t()
  def append_compaction(%__MODULE__{} = sm, summary, first_kept_entry_id, tokens_before, opts \\ []) do
    entry = %CompactionEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      summary: summary,
      first_kept_entry_id: first_kept_entry_id,
      tokens_before: tokens_before,
      details: Keyword.get(opts, :details),
      from_hook?: Keyword.get(opts, :from_hook, false)
    }

    append_entry(sm, entry)
  end

  @doc "Append a CustomEntry (extension state — NOT sent to the LLM)."
  @spec append_custom_entry(t(), String.t(), term()) :: t()
  def append_custom_entry(%__MODULE__{} = sm, custom_type, data \\ nil) do
    entry = %CustomEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      custom_type: custom_type,
      data: data
    }

    append_entry(sm, entry)
  end

  @doc """
  Append a CustomMessageEntry (extension-injected message sent to the LLM).

  Options:
    - `display` — whether to render in the TUI (default false)
    - `details` — opaque metadata (default nil)
  """
  @spec append_custom_message_entry(t(), String.t(), CustomMessageEntry.content(), keyword()) :: t()
  def append_custom_message_entry(%__MODULE__{} = sm, custom_type, content, opts \\ []) do
    entry = %CustomMessageEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      custom_type: custom_type,
      content: content,
      display: Keyword.get(opts, :display, false),
      details: Keyword.get(opts, :details)
    }

    append_entry(sm, entry)
  end

  @doc "Append a LabelEntry bookmarking `entry_id`. Pass `label: nil` to remove."
  @spec append_label(t(), String.t(), String.t() | nil) :: t()
  def append_label(%__MODULE__{} = sm, entry_id, label) do
    entry = %LabelEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      entry_id: entry_id,
      label: label
    }

    append_entry(sm, entry)
  end

  @doc """
  Append a BranchSummaryEntry for a tree navigation.

  `summary` is the LLM-generated summary of the abandoned branch.
  `from_id` is the leaf_id before navigation (the entry being abandoned).
  """
  @spec append_branch_summary(t(), String.t(), String.t()) :: t()
  def append_branch_summary(%__MODULE__{} = sm, summary, from_id) do
    entry = %BranchSummaryEntry{
      id: next_id(sm),
      parent_id: sm.leaf_id,
      timestamp: timestamp(),
      from_id: from_id,
      summary: summary
    }

    append_entry(sm, entry)
  end

  @doc "Append multiple messages in order. Equivalent to folding `append_message/2`."
  @spec append_messages(t(), [Message.t()]) :: t()
  def append_messages(%__MODULE__{} = sm, messages) when is_list(messages) do
    Enum.reduce(messages, sm, &append_message(&2, &1))
  end

  @doc """
  Append a pre-built entry directly (used for branching, loading, etc.).
  Sets parent_id and id if provided by the caller; does NOT override them.
  """
  @spec append(t(), SessionEntry.t()) :: t()
  def append(%__MODULE__{} = sm, entry) do
    append_entry(sm, entry)
  end

  # ── Tree traversal ───────────────────────────────────────────────────────────

  @doc """
  Return the linear path from the root to the current leaf, oldest-first.

  Algorithm: start at `leaf_id`, follow `parent_id` links until nil, reverse.
  Reference: pi-mono lines 1034-1043.
  """
  @spec get_branch(t()) :: [SessionEntry.t()]
  def get_branch(%__MODULE__{leaf_id: nil}), do: []

  def get_branch(%__MODULE__{} = sm), do: walk_to_root(sm, sm.leaf_id, [])

  @doc "Return the path from root to `from_id`, oldest-first."
  @spec get_branch(t(), String.t()) :: [SessionEntry.t()]
  def get_branch(%__MODULE__{} = sm, from_id), do: walk_to_root(sm, from_id, [])

  @doc """
  Return the latest CompactionEntry in the manager's entry list, or nil.

  Walks entries in reverse (newest-first) for O(1) in the common case.
  Reference: pi-mono lines 301-308.
  """
  @spec get_latest_compaction_entry(t()) :: CompactionEntry.t() | nil
  def get_latest_compaction_entry(%__MODULE__{entries: entries}) do
    Enum.find(Enum.reverse(entries), &match?(%CompactionEntry{}, &1))
  end

  # ── Context building ─────────────────────────────────────────────────────────

  @doc """
  Build the message list (and model/thinking metadata) to send to the LLM.

  This is the primary read path — every LLM call goes through here.

  Algorithm (port of pi-mono buildSessionContext lines 315-422):
    1. Walk the branch from root to leaf.
    2. Find the latest CompactionEntry.
    3a. If found: emit one synthetic User message with `entry.summary` first,
        then include only entries at or after `first_kept_entry_id`.
    3b. If not found: include all entries from the branch.
    4. From entries: MessageEntry → entry.message; CustomMessageEntry →
       synthetic User message. All other types are skipped.
    5. Model and thinking_level from the latest ModelChangeEntry (nil / :off
       if none exists).

  Returns `%{messages: [...], model: ..., thinking_level: atom()}`.
  """
  @spec build_session_context(t()) :: %{
          messages: [Message.t()],
          model: map() | nil,
          thinking_level: atom()
        }
  def build_session_context(%__MODULE__{} = sm) do
    branch = get_branch(sm)
    compaction = find_latest_compaction_in_branch(branch)

    messages = build_messages(branch, compaction)
    {model, thinking_level} = extract_model_info(branch)

    %{messages: messages, model: model, thinking_level: thinking_level}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp next_id(%__MODULE__{by_id: by_id}) do
    SessionEntry.generate_id(MapSet.new(Map.keys(by_id)))
  end

  defp timestamp, do: DateTime.to_iso8601(DateTime.utc_now())

  defp append_entry(%__MODULE__{entries: entries, by_id: by_id} = sm, entry) do
    sm = %{sm | entries: entries ++ [entry], by_id: Map.put(by_id, entry.id, entry), leaf_id: entry.id}
    persist_entry(sm, entry)
  end

  defp persist_entry(%__MODULE__{session_file: nil} = sm, _entry), do: sm

  defp persist_entry(%__MODULE__{session_file: path, flushed?: false} = sm, _entry) do
    has_assistant = Enum.any?(sm.entries, &match?(%MessageEntry{message: %Assistant{}}, &1))

    if has_assistant do
      File.write!(path, Enum.map_join(sm.entries, "\n", &Jason.encode!(SessionEntry.to_json(&1))) <> "\n")
      %{sm | flushed?: true}
    else
      sm
    end
  end

  defp persist_entry(%__MODULE__{session_file: path, flushed?: true} = sm, entry) do
    File.write!(path, Jason.encode!(SessionEntry.to_json(entry)) <> "\n", [:append])
    sm
  end

  defp walk_to_root(_sm, nil, acc), do: acc

  defp walk_to_root(%__MODULE__{by_id: by_id} = sm, id, acc) do
    case Map.get(by_id, id) do
      nil -> acc
      entry -> walk_to_root(sm, entry.parent_id, [entry | acc])
    end
  end

  defp find_latest_compaction_in_branch(branch) do
    Enum.find(Enum.reverse(branch), &match?(%CompactionEntry{}, &1))
  end

  defp build_messages(branch, nil) do
    Enum.flat_map(branch, &entry_to_messages/1)
  end

  defp build_messages(branch, %CompactionEntry{} = compaction) do
    summary_msg = %User{
      content: compaction.summary,
      timestamp: :os.system_time(:millisecond)
    }

    kept = drop_before(branch, compaction.first_kept_entry_id)
    [summary_msg | Enum.flat_map(kept, &entry_to_messages/1)]
  end

  defp drop_before(entries, target_id) do
    Enum.drop_while(entries, &(&1.id != target_id))
  end

  defp entry_to_messages(%MessageEntry{message: msg}), do: [msg]

  defp entry_to_messages(%CustomMessageEntry{content: content}) do
    text =
      case content do
        str when is_binary(str) -> str
        blocks -> Enum.map_join(blocks, "\n", &block_text/1)
      end

    [%User{content: text, timestamp: :os.system_time(:millisecond)}]
  end

  defp entry_to_messages(%BranchSummaryEntry{summary: summary}) do
    [%User{content: "[Branch summary: #{summary}]", timestamp: :os.system_time(:millisecond)}]
  end

  defp entry_to_messages(_other), do: []

  defp block_text(%{text: t}), do: t
  defp block_text(other), do: inspect(other)

  defp extract_model_info(branch) do
    model_entry = Enum.find(Enum.reverse(branch), &match?(%ModelChangeEntry{}, &1))

    model =
      case model_entry do
        %ModelChangeEntry{provider: p, model_id: m} -> %{provider: p, model_id: m}
        nil -> nil
      end

    {model, :off}
  end
end
