defmodule OctoPi.Coder.ResourceLoader do
  @moduledoc """
  Aggregates all prompt-composition sources for a session.

  Runs all sub-loaders (ContextFiles, PromptFiles, Skills,
  PromptTemplates) and collects results into a single struct.
  """

  alias OctoPi.Coder.PromptTemplates
  alias OctoPi.Coder.ResourceLoader.ContextFiles
  alias OctoPi.Coder.ResourceLoader.PromptFiles
  alias OctoPi.Coder.ResourceLoader.Skills
  alias OctoPi.Coder.SystemPrompt

  @type t :: %__MODULE__{
          context_files: [ContextFiles.context_file()],
          system_prompt: String.t() | nil,
          append_system_prompt: String.t() | nil,
          skills: [Skills.skill()],
          prompt_templates: [PromptTemplates.template()]
        }

  defstruct context_files: [],
            system_prompt: nil,
            append_system_prompt: nil,
            skills: [],
            prompt_templates: []

  @doc """
  Load all prompt-composition sources for `cwd`.

  `agent_dir` is the global config directory (e.g. `~/.pi/`). Pass
  `nil` to skip global sources.
  """
  @spec load(String.t(), String.t() | nil) :: t()
  def load(cwd, agent_dir) do
    %__MODULE__{
      context_files: ContextFiles.load_all(cwd, agent_dir),
      system_prompt: PromptFiles.load_system_prompt(cwd, agent_dir),
      append_system_prompt: PromptFiles.load_append_system_prompt(cwd, agent_dir),
      skills: Skills.load_all(cwd, agent_dir),
      prompt_templates: PromptTemplates.load_all(cwd, agent_dir)
    }
  end

  @doc """
  Render the system prompt for a session using the loaded resources.

  Passes context_files, skills, custom_prompt, and append to
  `SystemPrompt.render/1`. Uses the default body when no custom
  system prompt file was loaded.
  """
  @spec build_system_prompt(t(), String.t(), [OctoPi.Agent.Tool.t()]) :: String.t()
  def build_system_prompt(%__MODULE__{} = loader, cwd, tools) do
    SystemPrompt.render(
      cwd: cwd,
      tools: tools,
      context_files: loader.context_files,
      skills: loader.skills,
      custom_prompt: loader.system_prompt,
      append: loader.append_system_prompt
    )
  end
end
