defmodule OctoPi.Coder.Event do
  @moduledoc """
  Coder-level events dispatched alongside `OctoPi.Agent`'s kernel
  events on the same subscriber stream. Listeners receive them as
  `{:octo_pi_agent_event, %OctoPi.Coder.Event....{}}` tuples (the
  envelope is shared with Agent events because Coder uses Agent's
  Subscribers registry to fan out).

  Mirrors upstream `agent-session.ts` events: `compaction_start`,
  `compaction_end`. Distinct from `OctoPi.Agent.Event.CompactionRequested`
  / `.CompactionEnd` (which are kernel-level FSM events for the
  mid-run path only). Coder-level events fire for *every* compaction
  trigger — manual, pre-prompt, mid-run.
  """

  defmodule CompactionStart do
    @moduledoc """
    Emitted when a compaction begins. `:reason` is one of:
      * `:manual`     — user invoked `Coder.compact/2`
      * `:pre_prompt` — threshold tripped before forwarding a prompt
      * `:mid_run`    — Agent paused mid-multi-turn and asked the host
      * `:overflow`   — context-overflow recovery (future)
    """
    @enforce_keys [:reason]
    defstruct [:reason]

    @type reason :: :manual | :pre_prompt | :mid_run | :overflow
    @type t :: %__MODULE__{reason: reason()}
  end

  defmodule CompactionEnd do
    @moduledoc """
    Emitted when a compaction settles. `:result` is the
    `compact_result()` shape (`{:ok, _}` / `{:cancel, _}` /
    `{:error, _}`); `:reason` mirrors `CompactionStart`. `:aborted?`
    is true if the compaction was cancelled mid-flight.
    """
    @enforce_keys [:result, :reason]
    defstruct [:result, :reason, aborted?: false]

    @type t :: %__MODULE__{
            result: term(),
            reason: CompactionStart.reason(),
            aborted?: boolean()
          }
  end
end
