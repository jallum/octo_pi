defmodule OctoPi.TUI.Autocomplete.Suggestion do
  @moduledoc false
  @enforce_keys [:label, :value]
  @type t :: %__MODULE__{
          label: String.t(),
          value: String.t(),
          description: String.t() | nil
        }
  defstruct [:label, :value, :description]
end
