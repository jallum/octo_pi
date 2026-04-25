defmodule OctoPi.Coder.ResourceLoader.PromptFiles do
  @moduledoc """
  Loads file-based system prompt overrides and append-system-prompt
  files.

  Mirrors upstream pi-mono's `discoverSystemPromptFile()` and
  `discoverAppendSystemPromptFile()` in `resource-loader.ts`.

  Both functions use the same project-first, global-fallback pattern:
  - project: `{cwd}/.pi/{FILENAME}`
  - global: `{agent_dir}/{FILENAME}`
  """

  @config_dir ".pi"

  @doc """
  Load the system prompt override for `cwd`.

  Returns the file contents when `{cwd}/.pi/SYSTEM.md` exists, falling
  back to `{agent_dir}/SYSTEM.md`. Returns `nil` when neither exists.
  When `agent_dir` is `nil`, only the project path is checked.
  """
  @spec load_system_prompt(String.t(), String.t() | nil) :: String.t() | nil
  def load_system_prompt(cwd, agent_dir) do
    load_first([
      Path.join([cwd, @config_dir, "SYSTEM.md"]),
      agent_dir && Path.join(agent_dir, "SYSTEM.md")
    ])
  end

  @doc """
  Load the append-system-prompt for `cwd`.

  Returns the file contents when `{cwd}/.pi/APPEND_SYSTEM.md` exists,
  falling back to `{agent_dir}/APPEND_SYSTEM.md`. Returns `nil` when
  neither exists.
  """
  @spec load_append_system_prompt(String.t(), String.t() | nil) :: String.t() | nil
  def load_append_system_prompt(cwd, agent_dir) do
    load_first([
      Path.join([cwd, @config_dir, "APPEND_SYSTEM.md"]),
      agent_dir && Path.join(agent_dir, "APPEND_SYSTEM.md")
    ])
  end

  defp load_first(paths) do
    Enum.find_value(paths, fn
      nil -> nil
      path -> read_if_exists(path)
    end)
  end

  defp read_if_exists(path) do
    case File.read(path) do
      {:ok, content} when content != "" -> content
      _ -> nil
    end
  end
end
