defmodule OctoPi.TUI.Components.DynamicBorder do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Theme

  @type t :: %__MODULE__{theme: Theme.t()}

  defstruct [:theme]

  @spec new(Theme.t()) :: t()
  def new(theme), do: %__MODULE__{theme: theme}

  @impl true
  @spec render(t(), pos_integer()) :: [String.t()]
  def render(%__MODULE__{theme: theme}, width) do
    rule = String.duplicate("─", width)
    [Theme.fg(theme, :border_muted, rule)]
  end
end
