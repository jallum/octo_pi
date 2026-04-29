defmodule OctoPi.AI.CallOptions do
  @moduledoc false

  alias OctoPi.AI.Model

  @type t :: %__MODULE__{
          temperature: float() | nil,
          max_tokens: pos_integer() | nil,
          api_key: String.t() | nil,
          metadata: map() | nil,
          headers: %{optional(String.t()) => String.t()} | nil,
          reasoning: OctoPi.AI.thinking_level() | nil,
          thinking_budgets: OctoPi.AI.thinking_budgets() | nil,
          on_payload: (map(), Model.t() -> map() | nil) | nil,
          on_response: (map(), Model.t() -> :ok) | nil
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
