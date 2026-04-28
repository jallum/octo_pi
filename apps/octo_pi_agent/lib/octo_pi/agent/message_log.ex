defmodule OctoPi.Agent.MessageLog do
  @moduledoc """
  Append-friendly log of agent messages.

  Stored newest-first internally so `push/2` and `append_many/2` are
  O(1) (or O(k) in the size of the new chunk, but never O(n) in the
  existing transcript). Exposed oldest-first via `to_list/1`, which
  uses the BIF `:lists.reverse/1` (runs in C).

  Replaces the `list ++ [item]` append pattern that dominated the
  Session/Loop hot paths and was O(n²) over a long transcript. A
  cached `count` field also turns `length(messages)` callers (telemetry
  metadata, etc.) into O(1) reads.

  Opaque struct: callers should always go through the API. Anything
  that needs a plain list calls `to_list/1`; anything that constructs
  a log from an oldest-first list (e.g. session init from opts) calls
  `new/1`.
  """

  @opaque t :: %__MODULE__{rev: [term()], count: non_neg_integer()}

  defstruct rev: [], count: 0

  @doc """
  Build a log from an oldest-first list (or empty list by default).
  Stored internally as newest-first.
  """
  @spec new([term()]) :: t()
  def new(list \\ []) when is_list(list) do
    %__MODULE__{rev: Enum.reverse(list), count: length(list)}
  end

  @doc "Append one message to the end of the log. O(1)."
  @spec push(t(), term()) :: t()
  def push(%__MODULE__{rev: rev, count: count}, msg) do
    %__MODULE__{rev: [msg | rev], count: count + 1}
  end

  @doc """
  Append an oldest-first list of messages to the end of the log.
  Single pass via the 2-arg form of `Enum.reverse/2`, which reverses
  `msgs` *and* prepends them to `rev` in one walk.
  """
  @spec append_many(t(), [term()]) :: t()
  def append_many(%__MODULE__{} = log, []), do: log

  def append_many(%__MODULE__{rev: rev, count: count}, msgs) when is_list(msgs) do
    %__MODULE__{rev: Enum.reverse(msgs, rev), count: count + length(msgs)}
  end

  @doc "Return the log as an oldest-first list. O(n) via the BIF."
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{rev: rev}), do: :lists.reverse(rev)

  @doc "Number of messages in the log. O(1) — reads the cached counter."
  @spec count(t()) :: non_neg_integer()
  def count(%__MODULE__{count: count}), do: count

  @doc """
  Remove the last (newest) message from the log. O(1). Returns the
  original log unchanged if it is empty.
  """
  @spec pop(t()) :: t()
  def pop(%__MODULE__{rev: [_ | rest], count: count}), do: %__MODULE__{rev: rest, count: count - 1}
  def pop(%__MODULE__{rev: []} = log), do: log

  @doc """
  Scan the log from newest to oldest, returning the first non-nil
  value produced by `fun/1`, or `nil` if none match. Equivalent to
  `Enum.find_value/2` over `to_list/1` but without the O(n) reversal.
  """
  @spec find_last_value(t(), (term() -> term() | nil)) :: term() | nil
  def find_last_value(%__MODULE__{rev: rev}, fun), do: Enum.find_value(rev, fun)
end
