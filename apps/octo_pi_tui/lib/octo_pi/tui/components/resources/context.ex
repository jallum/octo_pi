defmodule OctoPi.TUI.Components.Resources.Context do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{files: [%{path: String.t()}], expanded: boolean()}

  defstruct files: [], expanded: false

  @spec new([%{path: String.t()}]) :: t()
  def new(files), do: %__MODULE__{files: files}

  @impl true
  def render(%{files: []} = self, _), do: {self, %VDOM.VLines{lines: []}}

  def render(%{files: files, expanded: expanded} = self, %{theme: theme}) do
    body =
      if expanded do
        Enum.map_join(files, "\n", &("  " <> dim(&1.path)))
      else
        dim("  " <> Enum.map_join(files, ", ", &Path.basename(&1.path)))
      end

    {self, %VDOM.VLines{lines: [section_header(theme, "Context"), body, ""]}}
  end

  defp section_header(nil, name), do: "[#{name}]"
  defp section_header(theme, name), do: Theme.fg(theme, :md_heading, "[#{name}]")

  defp dim(text), do: "\e[2m#{text}\e[22m"
end
