defmodule OctoPi.Agent.Extension do
  @moduledoc """
  Behaviour for session extensions. Extensions receive lifecycle events and can
  cancel, modify, or simply observe them — complementing `Subscribers` (which is
  notification-only and fire-and-forget).

  `on_event/3` is optional. If a module does not export it, the runner skips
  that module for every event.

  Return values:
    - `:ok` — no modification, let the event continue
    - `{:ok, modifications}` — merge `modifications` into the accumulator (for
      result-modifiable events)
    - `{:cancel, reason}` — stop dispatch and return `{:cancelled, reason}` to
      the caller (for cancellable events only)
  """

  alias OctoPi.Agent.AbortRef

  @type event_result ::
          :ok
          | {:ok, modifications :: map()}
          | {:cancel, reason :: term()}

  @type ctx :: %{
          session_pid: pid(),
          is_idle?: boolean(),
          signal: AbortRef.t() | nil
        }

  @callback on_event(event_type :: atom(), payload :: map(), ctx :: ctx()) :: event_result()

  @optional_callbacks [on_event: 3]
end
