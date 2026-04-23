defmodule OctoPi.AI.Usage do
  @moduledoc """
  Token usage counts and cost breakdown for a single provider call.

  Mirrors pi-ai's `Usage` interface (`types.ts`). Anthropic never sends
  `total_tokens`, so it is always computed as
  `input + output + cache_read + cache_write`.
  """

  alias OctoPi.AI.Usage.Cost

  @type t :: %__MODULE__{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          total_tokens: non_neg_integer(),
          cost: Cost.t()
        }

  defstruct input: 0,
            output: 0,
            cache_read: 0,
            cache_write: 0,
            total_tokens: 0,
            cost: %Cost{}
end
