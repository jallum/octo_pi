defmodule OctoPi.Coder.Compaction do
  @moduledoc """
  Compaction orchestration. Port of upstream `compact`
  (`tmp/pi-mono/.../compaction/compaction.ts:717-797`).

  Two paths:

  - **single-pass** — one `Summary.generate/4` call over
    `messages_to_summarize`. Hit when the cut isn't a split turn (or it
    is, but `turn_prefix_messages` is empty).
  - **split-turn parallel** — history and turn-prefix summaries run in
    parallel via `Task.async/1` and are merged with the upstream
    separator: `\\n\\n---\\n\\n**Turn Context (split turn):**\\n\\n`.
    `custom_instructions` and `previous_summary` only flow into the
    history call; the turn-prefix call uses
    `Summary.generate(..., variant: :turn_prefix)` (0.5 × reserve).

  In both paths, `<read-files>` / `<modified-files>` blocks are appended
  to the resulting summary.
  """

  alias OctoPi.AI.Model
  alias OctoPi.Coder.Compaction.Preparation
  alias OctoPi.Coder.Compaction.Result

  @type opts :: [
          api_key: String.t() | nil,
          headers: map() | nil,
          custom_instructions: String.t() | nil,
          thinking_level: atom() | nil,
          producer: module() | function()
        ]

  @doc """
  Async compaction. Spawns a worker process that runs the LLM
  streaming + summary build, sending `{:compact_done, ref, result}`
  to `parent` when done. The worker also handles `:abort` messages
  (graceful cancel) and `Process.exit(:kill)` (brutal cancel).

  This is the primary entry point. The legacy synchronous
  `compact/3` shim (below) wraps `async/5` for tests / contexts that
  don't need cancellation.
  """
  @spec async(pid(), reference(), Preparation.t(), Model.t(), opts()) :: {:ok, pid()}
  def async(parent, ref, %Preparation{} = prep, %Model{} = model, opts \\ []) do
    pid = spawn(__MODULE__.Worker, :run, [parent, ref, prep, model, opts])
    {:ok, pid}
  end

  @doc """
  Synchronous wrapper around `async/5`. Spawns the worker, blocks on
  its `{:compact_done, ref, result}` reply. Used by tests and any
  caller that doesn't need cancellation.
  """
  @spec compact(Preparation.t(), Model.t(), opts()) ::
          {:ok, Result.t()} | {:error, term()} | {:cancel, :aborted}
  def compact(preparation, model, opts \\ [])

  def compact(%Preparation{} = prep, %Model{} = model, opts) do
    ref = make_ref()
    {:ok, _pid} = async(self(), ref, prep, model, opts)

    receive do
      {:compact_done, ^ref, result} -> result
    end
  end
end
