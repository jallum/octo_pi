defmodule OctoPi.AI.Tool do
  @moduledoc """
  A tool definition passed to the provider as part of a `Context`.

  `parameters` is a JSON Schema object (we store it as a plain map;
  upstream pi-ai uses typebox, which we don't port).
  """

  @enforce_keys [:name, :description, :parameters]
  @type t :: %__MODULE__{
          name: String.t(),
          description: String.t(),
          parameters: map()
        }

  defstruct [:name, :description, :parameters]
end
