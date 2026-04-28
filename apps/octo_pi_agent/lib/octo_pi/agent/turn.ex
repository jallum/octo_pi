defmodule OctoPi.Agent.Turn do
  @moduledoc """
  Pure FSM for a single agent turn. Driven by `OctoPi.Agent.Session`
  (lands in F2 / opi-ixp.50); no process, no I/O, no funs in struct
  fields. Session feeds events in via `handle_event/2` and executes
  the returned action list, then feeds the next event.

  Compaction states (`:compacting`) and auto-compact handling extend
  this FSM in F3–F5.

  ## States

    * `:idle` — no turn in flight.
    * `:awaiting_response` — a stream Task is running for the current
      turn.
    * `:executing_tools` — the assistant produced `:tool_use`; a tool
      batch Task is running. The assistant is held in
      `assistant_in_flight` until results arrive.
    * `:cancelling` — abort requested while busy. Late completion
      events from the cancelled Task are absorbed and produce a
      synthetic aborted `:turn_done`.
    * `:compacting` (F3) — `compact/1` invoked. Session has emitted
      `%Event.CompactionRequested{}` to subscribers and is awaiting
      a `compaction_response/3` call.

  ## Events accepted

    * External: `:prompt_received`, `:abort_requested`,
      `{:compact_requested, opts}` (F3).
    * Completion: `{:stream_done, assistant}`, `{:stream_failed,
      reason}`, `{:tool_batch_done, results}`,
      `{:compaction_response, result}` (F3).

  Unexpected `(state, event)` pairs raise `ArgumentError` — bugs in
  the executor should be loud.

  ## Actions

  Descriptors only — Session is the executor.

    * `:start_stream` — spawn the stream Task; on completion feed
      `{:stream_done, assistant}` or `{:stream_failed, reason}`.
    * `{:start_tool_batch, calls}` — spawn the tool batch Task; on
      completion feed `{:tool_batch_done, results}`. Parallel vs
      sequential dispatch is Session's responsibility (resolved from
      the tool definitions Turn does not carry).
    * `:cancel_active_task` — `Task.shutdown/2` on the tracked ref.
    * `{:start_compaction, opts}` (F3) — Session emits
      `%Event.CompactionRequested{ref, opts}` via Subscribers and
      sets `turn_ref` so the eventual response is ref-gateable.
    * `{:emit_event, struct}` — subscriber event (`%Event.TurnStart{}`
      / `%Event.TurnEnd{}` / `%Event.CompactionEnd{}` here).
    * `{:turn_done, assistant, tool_results, stop_reason}` — normal
      completion; assistant is the LLM-produced struct.
    * `{:turn_synth_done, stop_reason, error_message}` — synthesized
      completion (`:error` / `:aborted`). Session builds the
      aborted/error assistant from its own model + provider — Turn
      does not carry those.

  > Implementation deviation from opi-ixp.49 prose: actions land as
  > `{:start_tool_batch, calls}` (no mode arg) and a synth variant of
  > `:turn_done` for error/abort cases. Both because Turn cannot
  > author an `Assistant.t()` (its `@enforce_keys` need provider/model)
  > and shouldn't know about parallel-vs-sequential — Session has both
  > pieces.
  """

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.ToolCall

  @type state ::
          :idle | :awaiting_response | :executing_tools | :cancelling | :compacting

  @type compaction_result ::
          {:ok, map()} | {:cancel, term()} | {:error, term()}

  @type event ::
          :prompt_received
          | :abort_requested
          | {:stream_done, Assistant.t()}
          | {:stream_failed, term()}
          | {:tool_batch_done, [ToolResult.t()]}
          | {:compact_requested, keyword()}
          | {:compaction_response, compaction_result()}

  @type action ::
          :start_stream
          | {:start_tool_batch, [ToolCall.t()]}
          | :cancel_active_task
          | {:start_compaction, keyword()}
          | {:emit_event, struct()}
          | {:turn_done, Assistant.t(), [ToolResult.t()], Assistant.stop_reason()}
          | {:turn_synth_done, :error | :aborted, String.t()}

  @type t :: %__MODULE__{
          state: state(),
          id: non_neg_integer(),
          assistant_in_flight: Assistant.t() | nil
        }

  defstruct state: :idle, id: 0, assistant_in_flight: nil

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec handle_event(t(), event()) :: {t(), [action()]}

  # ---------- :idle ----------

  def handle_event(%__MODULE__{state: :idle} = turn, :prompt_received) do
    next_id = turn.id + 1
    turn = %{turn | state: :awaiting_response, id: next_id, assistant_in_flight: nil}
    {turn, [{:emit_event, %Event.TurnStart{turn: next_id}}, :start_stream]}
  end

  def handle_event(%__MODULE__{state: :idle} = turn, :abort_requested), do: {turn, []}

  def handle_event(%__MODULE__{state: :idle} = turn, {:compact_requested, opts}) do
    {%{turn | state: :compacting}, [{:start_compaction, opts}]}
  end

  # ---------- :awaiting_response ----------

  def handle_event(
        %__MODULE__{state: :awaiting_response} = turn,
        {:stream_done, %Assistant{stop_reason: :tool_use} = assistant}
      ) do
    calls = Enum.filter(assistant.content, &match?(%ToolCall{}, &1))
    {%{turn | state: :executing_tools, assistant_in_flight: assistant}, [{:start_tool_batch, calls}]}
  end

  def handle_event(
        %__MODULE__{state: :awaiting_response} = turn,
        {:stream_done, %Assistant{stop_reason: reason} = assistant}
      )
      when reason in [:stop, :length, :error] do
    finalize_turn(turn, assistant, reason)
  end

  def handle_event(%__MODULE__{state: :awaiting_response} = turn, {:stream_failed, reason}) do
    finalize_synth(turn, :error, "stream failed: #{inspect(reason)}")
  end

  def handle_event(%__MODULE__{state: :awaiting_response} = turn, :abort_requested) do
    {%{turn | state: :cancelling}, [:cancel_active_task]}
  end

  # ---------- :executing_tools ----------

  def handle_event(
        %__MODULE__{state: :executing_tools, assistant_in_flight: %Assistant{} = assistant} = turn,
        {:tool_batch_done, results}
      ) do
    finalize_turn(%{turn | assistant_in_flight: nil}, assistant, :tool_use, results)
  end

  def handle_event(%__MODULE__{state: :executing_tools} = turn, :abort_requested) do
    {%{turn | state: :cancelling}, [:cancel_active_task]}
  end

  # ---------- :cancelling ----------
  # Late completion events from the killed Task — drain and produce a
  # synthetic aborted turn_done.

  def handle_event(%__MODULE__{state: :cancelling} = turn, {:stream_done, _}),
    do: finalize_synth(turn, :aborted, "aborted by caller")

  def handle_event(%__MODULE__{state: :cancelling} = turn, {:stream_failed, _}),
    do: finalize_synth(turn, :aborted, "aborted by caller")

  def handle_event(%__MODULE__{state: :cancelling} = turn, {:tool_batch_done, _}),
    do: finalize_synth(turn, :aborted, "aborted by caller")

  def handle_event(%__MODULE__{state: :cancelling} = turn, :abort_requested), do: {turn, []}

  # ---------- :compacting ----------

  def handle_event(%__MODULE__{state: :compacting} = turn, {:compaction_response, result}) do
    {%{turn | state: :idle}, [{:emit_event, %Event.CompactionEnd{result: result}}]}
  end

  # Abort while compacting is a no-op — there's no Task on Agent's
  # side to kill (compaction is handled by an external subscriber via
  # CompactionRequested). The caller can still treat the in-flight
  # compaction as cancelled by ignoring the eventual reply.
  def handle_event(%__MODULE__{state: :compacting} = turn, :abort_requested), do: {turn, []}

  # ---------- catchall ----------

  def handle_event(%__MODULE__{state: state}, event) do
    raise ArgumentError, "Turn: unexpected event #{inspect(event)} in state #{inspect(state)}"
  end

  # ---------- helpers ----------

  defp finalize_turn(turn, assistant, stop_reason, tool_results \\ []) do
    turn = %{turn | state: :idle, assistant_in_flight: nil}

    actions = [
      {:emit_event, %Event.TurnEnd{turn: turn.id}},
      {:turn_done, assistant, tool_results, stop_reason}
    ]

    {turn, actions}
  end

  defp finalize_synth(turn, stop_reason, error_message) do
    turn = %{turn | state: :idle, assistant_in_flight: nil}

    actions = [
      {:emit_event, %Event.TurnEnd{turn: turn.id}},
      {:turn_synth_done, stop_reason, error_message}
    ]

    {turn, actions}
  end
end
