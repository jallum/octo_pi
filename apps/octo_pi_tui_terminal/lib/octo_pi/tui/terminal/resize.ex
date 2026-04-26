defmodule OctoPi.TUI.Terminal.Resize do
  @moduledoc "A terminal resize event in cells."

  @enforce_keys [:width, :height]
  defstruct [:width, :height]

  @type t :: %__MODULE__{width: pos_integer(), height: pos_integer()}
end
