defmodule OctoPi.AI.Usage.Cost do
  @moduledoc """
  Dollar cost breakdown for a single provider call, matching `Usage.cost`
  in pi-ai's `types.ts`.
  """

  @type t :: %__MODULE__{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float(),
          total: float()
        }

  defstruct input: 0.0,
            output: 0.0,
            cache_read: 0.0,
            cache_write: 0.0,
            total: 0.0
end
