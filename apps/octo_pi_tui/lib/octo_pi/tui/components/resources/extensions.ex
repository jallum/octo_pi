defmodule OctoPi.TUI.Components.Resources.Extensions do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{extensions: [%{name: String.t()}], expanded: boolean()}

  defstruct extensions: [], expanded: false

  @spec new([%{name: String.t()}]) :: t()
  def new(extensions), do: %__MODULE__{extensions: extensions}

  @impl true
  def render(%__MODULE__{extensions: []} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}}

  def render(%__MODULE__{extensions: extensions, expanded: expanded} = self, %RenderContext{theme: theme}) do
    body =
      if expanded do
        Enum.map_join(extensions, "\n", &("  " <> Theme.dim(&1.name)))
      else
        Theme.dim("  " <> Enum.map_join(extensions, ", ", & &1.name))
      end

    {self, %VDOM.VLines{lines: [section_header(theme, "Extensions"), body, ""]}}
  end

  defp section_header(nil, name), do: "[#{name}]"
  defp section_header(theme, name), do: Theme.fg(theme, :md_heading, "[#{name}]")
end
