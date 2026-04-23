defmodule OctoPi.Agent.AbortRef do
  @moduledoc """
  Cooperative cancellation flag, ported from pi-agent-core's
  `AbortSignal` pattern. See `docs/port-map/agent.md` §4, §10.2.

  One flag per run. Created by `new/0`, set by `abort/1`, polled by
  `aborted?/1`. The flag lives in an ETS table (`:octo_pi_agent_abort_flags`)
  owned by `OctoPi.Agent.AbortRegistry` — see the app's supervision
  tree — with read concurrency enabled, so `aborted?/1` is
  lock-free.

  Hard abort still goes through `Task.shutdown/2` at the loop level —
  this flag covers the cooperative path: tools / hooks / handlers
  that poll and bail out cleanly.
  """

  @table :octo_pi_agent_abort_flags

  @opaque t :: reference()

  @doc "Create a new abort ref. Flag starts cleared."
  @spec new() :: t()
  def new do
    ref = make_ref()
    :ets.insert(@table, {ref, false})
    ref
  end

  @doc "Raise the flag. Idempotent."
  @spec abort(t()) :: :ok
  def abort(ref) when is_reference(ref) do
    :ets.insert(@table, {ref, true})
    :ok
  end

  @doc """
  Read the flag. Returns `true` if set, `false` otherwise. Cheap —
  backed by a read-concurrent ETS lookup.
  """
  @spec aborted?(t()) :: boolean()
  def aborted?(ref) when is_reference(ref) do
    case :ets.lookup(@table, ref) do
      [{^ref, flag}] -> flag
      [] -> false
    end
  end

  @doc """
  Delete the ref's row. Called at session end. `aborted?/1` on a
  forgotten ref returns `false`.
  """
  @spec forget(t()) :: :ok
  def forget(ref) when is_reference(ref) do
    :ets.delete(@table, ref)
    :ok
  end

  @doc false
  def table_name, do: @table
end
