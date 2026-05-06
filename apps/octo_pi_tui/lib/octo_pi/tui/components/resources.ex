defmodule OctoPi.TUI.Components.Resources do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Resources.Context
  alias OctoPi.TUI.Components.Resources.Extensions
  alias OctoPi.TUI.Components.Resources.Prompts
  alias OctoPi.TUI.Components.Resources.Skills
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{
          context: Context.t(),
          skills: Skills.t(),
          prompts: Prompts.t(),
          extensions: Extensions.t(),
          expanded: boolean()
        }

  defstruct context: %Context{}, skills: %Skills{}, prompts: %Prompts{}, extensions: %Extensions{}, expanded: false

  @spec new(%{context_files: list(), skills: list(), prompt_templates: list(), extensions: list()}) :: t()
  def new(data) do
    %__MODULE__{
      context: Context.new(data.context_files),
      skills: Skills.new(data.skills),
      prompts: Prompts.new(data.prompt_templates),
      extensions: Extensions.new(data.extensions)
    }
  end

  @impl true
  def render(%{expanded: expanded} = self, ctx) do
    {_, c_vnode} = Context.render(%{self.context | expanded: expanded}, ctx)
    {_, s_vnode} = Skills.render(%{self.skills | expanded: expanded}, ctx)
    {_, p_vnode} = Prompts.render(%{self.prompts | expanded: expanded}, ctx)
    {_, e_vnode} = Extensions.render(%{self.extensions | expanded: expanded}, ctx)
    {self, %VDOM.VFlow{children: [c_vnode, s_vnode, p_vnode, e_vnode]}}
  end
end
