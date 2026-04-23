defmodule OctoPi.AI.Model.Cost do
  @moduledoc """
  Per-million-token pricing for a model, in dollars.
  """

  @type t :: %__MODULE__{
          input: float(),
          output: float(),
          cache_read: float(),
          cache_write: float()
        }

  defstruct input: 0.0, output: 0.0, cache_read: 0.0, cache_write: 0.0
end
