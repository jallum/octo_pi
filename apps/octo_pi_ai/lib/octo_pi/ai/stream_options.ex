defmodule OctoPi.AI.StreamOptions do
  @moduledoc """
  Per-call options threaded into a provider's `stream/3` and
  `stream_simple/3`. Phase 1 carries the subset of pi-ai's
  `StreamOptions` + `SimpleStreamOptions` that the Anthropic provider
  actually uses.

  - `api_key` — overrides the env-var lookup when set.
  - `metadata` — pass-through map; Anthropic extracts `user_id`.
  - `headers` — extra HTTP headers merged onto the provider defaults.
  - `reasoning` — thinking level for the `stream_simple` entry.
  - `thinking_budgets` — token-based override for `:reasoning` on
    budget-thinking models (e.g. pre-Opus 4.6 Claude).

  - `on_payload` — `(body :: map(), model :: Model.t()) -> map() | nil`;
    called with the built request body before the HTTP call. Return a
    modified body to override, or `nil` to keep the original.
  - `on_response` — `(info :: map(), model :: Model.t()) -> :ok`;
    called with `%{status: integer(), headers: map()}` after the
    response starts.

  Deferred to later phases: `transport`, `cache_retention`,
  `max_retry_delay_ms`, `signal` (abort-via-pid — cancellation is
  currently implemented by killing the producer Task),
  `session_id` (tied to prompt caching).
  """

  alias OctoPi.AI.Model

  @type thinking_level :: :minimal | :low | :medium | :high | :xhigh

  @type thinking_budgets :: %{optional(thinking_level()) => pos_integer()}

  @type on_payload :: (map(), Model.t() -> map() | nil) | nil
  @type on_response :: (map(), Model.t() -> :ok) | nil

  @type t :: %__MODULE__{
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          api_key: String.t() | nil,
          metadata: map() | nil,
          headers: %{optional(String.t()) => String.t()} | nil,
          reasoning: thinking_level() | nil,
          thinking_budgets: thinking_budgets() | nil,
          on_payload: on_payload(),
          on_response: on_response()
        }

  defstruct [
    :temperature,
    :max_tokens,
    :api_key,
    :metadata,
    :headers,
    :reasoning,
    :thinking_budgets,
    :on_payload,
    :on_response
  ]
end
