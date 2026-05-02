defmodule OctoPi.TUI.Components.Resources.Skills do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{skills: [%{name: String.t()}], expanded: boolean()}

  defstruct skills: [], expanded: false

  @spec new([%{name: String.t()}]) :: t()
  def new(skills), do: %__MODULE__{skills: skills}

  @impl true
  def render(%__MODULE__{skills: []} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}}

  def render(%__MODULE__{skills: skills, expanded: expanded} = self, %RenderContext{theme: theme}) do
    body =
      if expanded do
        Enum.map_join(skills, "\n", &("  " <> Theme.dim(&1.name)))
      else
        Theme.dim("  " <> Enum.map_join(skills, ", ", & &1.name))
      end

    {self, %VDOM.VLines{lines: [section_header(theme, "Skills"), body, ""]}}
  end

  defp section_header(nil, name), do: "[#{name}]"
  defp section_header(theme, name), do: Theme.fg(theme, :md_heading, "[#{name}]")
end
