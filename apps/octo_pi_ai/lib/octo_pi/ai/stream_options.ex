defmodule OctoPi.AI.StreamOptions do
  @moduledoc """
  Per-call options threaded into a provider's `stream/3` and
  `stream_simple/3`. Phase 1 carries the subset of pi-ai's
  `StreamOptions` + `SimpleStreamOptions` that the Anthropic provider
  actually uses.

  - `signal` — any pid; if that process dies, the stream producer exits
    and the HTTP request is cancelled (see `docs/port-map/anthropic.md`
    §7.2).
  - `api_key` — overrides the env-var lookup when set.
  - `metadata` — pass-through map; Anthropic extracts `user_id`.
  - `headers` — extra HTTP headers merged onto the provider defaults.
  - `session_id` — opaque session identifier for providers that support
    session-scoped caching.
  - `reasoning` — thinking level for the `stream_simple` entry.
  - `thinking_budgets` — token-based override for `:reasoning` on
    budget-thinking models (e.g. pre-Opus 4.6 Claude).

  Deferred to later phases: `transport`, `cache_retention`,
  `max_retry_delay_ms`, `on_payload`, `on_response`.
  """

  @type thinking_level :: :minimal | :low | :medium | :high | :xhigh

  @type thinking_budgets :: %{optional(thinking_level()) => pos_integer()}

  @type t :: %__MODULE__{
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          signal: pid() | nil,
          api_key: String.t() | nil,
          metadata: map() | nil,
          headers: %{optional(String.t()) => String.t()} | nil,
          session_id: String.t() | nil,
          reasoning: thinking_level() | nil,
          thinking_budgets: thinking_budgets() | nil
        }

  defstruct [
    :temperature,
    :max_tokens,
    :signal,
    :api_key,
    :metadata,
    :headers,
    :session_id,
    :reasoning,
    :thinking_budgets
  ]
end
