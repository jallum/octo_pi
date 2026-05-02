defmodule OctoPi.TUI.Components.Resources.Prompts do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{templates: [%{name: String.t()}], expanded: boolean()}

  defstruct templates: [], expanded: false

  @spec new([%{name: String.t()}]) :: t()
  def new(templates), do: %__MODULE__{templates: templates}

  @impl true
  def render(%__MODULE__{templates: []} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}}

  def render(%__MODULE__{templates: templates, expanded: expanded} = self, %RenderContext{theme: theme}) do
    body =
      if expanded do
        Enum.map_join(templates, "\n", &("  " <> dim("/#{&1.name}")))
      else
        dim("  " <> Enum.map_join(templates, ", ", &"/#{&1.name}"))
      end

    {self, %VDOM.VLines{lines: [section_header(theme, "Prompts"), body, ""]}}
  end

  defp section_header(nil, name), do: "[#{name}]"
  defp section_header(theme, name), do: Theme.fg(theme, :md_heading, "[#{name}]")

  defp dim(text), do: "\e[2m#{text}\e[22m"
end
