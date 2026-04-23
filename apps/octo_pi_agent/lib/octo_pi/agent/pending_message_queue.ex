defmodule OctoPi.Agent.PendingMessageQueue do
  @moduledoc """
  Bounded FIFO of messages waiting to be injected into a run. Used
  for the steering queue (drained after each turn, before the next
  LLM call) and the follow-up queue (drained only when the loop
  would otherwise stop).

  Implementation lives in `octo-z1d.5`; this file pins the struct
  shape so contract tickets can reference it.
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

  @doc false
  # Full behaviour (enqueue/drain/clear/has_items?) lands in octo-z1d.5.
  def empty?(%__MODULE__{count: 0}), do: true
  def empty?(%__MODULE__{}), do: false
end
