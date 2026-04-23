defmodule OctoPi.Agent.PendingMessageQueue do
  @moduledoc """
  Bounded FIFO of messages waiting to be injected into a run. Used
  for the steering queue (drained at the top of every loop
  iteration, before the next LLM call) and the follow-up queue
  (drained when the loop would otherwise terminate).

  Modes:
    * `:one_at_a_time` — `drain/1` returns a single head item
    * `:all`           — `drain/1` returns every queued item, clearing
  """

  alias OctoPi.Agent.Message

  @default_bound 1_000

  @type mode :: :one_at_a_time | :all

  @type t :: %__MODULE__{
          items: :queue.queue(Message.t()),
          count: non_neg_integer(),
          bound: pos_integer(),
          mode: mode()
        }

  defstruct items: nil, count: 0, bound: @default_bound, mode: :one_at_a_time

  @doc "Construct an empty queue."
  @spec new(mode(), pos_integer()) :: t()
  def new(mode \\ :one_at_a_time, bound \\ @default_bound) when mode in [:one_at_a_time, :all] do
    %__MODULE__{items: :queue.new(), count: 0, bound: bound, mode: mode}
  end

  @doc "True iff the queue has no items."
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{count: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc "True iff the queue has at least one item."
  @spec has_items?(t()) :: boolean()
  def has_items?(%__MODULE__{count: 0}), do: false
  def has_items?(%__MODULE__{}), do: true

  @doc """
  Enqueue a message. Returns `{:error, :full}` if the queue is at
  its configured `bound`.
  """
  @spec enqueue(t(), Message.t()) :: {:ok, t()} | {:error, :full}
  def enqueue(%__MODULE__{count: c, bound: b}, _msg) when c >= b, do: {:error, :full}

  def enqueue(%__MODULE__{items: items, count: c} = q, msg) do
    {:ok, %{q | items: :queue.in(msg, items), count: c + 1}}
  end

  @doc """
  Drain according to `mode`. Returns `{messages, new_queue}`.
  `:one_at_a_time` returns at most one item; `:all` returns all and
  leaves the queue empty.
  """
  @spec drain(t()) :: {[Message.t()], t()}
  def drain(%__MODULE__{count: 0} = q), do: {[], q}

  def drain(%__MODULE__{mode: :all, items: items} = q) do
    {:queue.to_list(items), %{q | items: :queue.new(), count: 0}}
  end

  def drain(%__MODULE__{mode: :one_at_a_time, items: items, count: c} = q) do
    {{:value, item}, rest} = :queue.out(items)
    {[item], %{q | items: rest, count: c - 1}}
  end

  @doc "Clear the queue (no items returned)."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = q), do: %{q | items: :queue.new(), count: 0}
end
