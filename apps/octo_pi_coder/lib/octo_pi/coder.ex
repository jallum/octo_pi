defmodule OctoPi.Coder do
  @moduledoc """
  Coding-agent core: the application layer that composes the
  `OctoPi.Agent` kernel with a JSONL session store, built-in file +
  bash + search tools, and the Print output mode.

  Entry points:

      OctoPi.Coder.run_print(opts)   # non-interactive single-shot run
      OctoPi.Coder.default_tools(cwd)
  """

  alias OctoPi.Agent.Tool
  alias OctoPi.AI.Model
  alias OctoPi.Coder.Modes.Print
  alias OctoPi.Coder.ResourceLoader
  alias OctoPi.Coder.Tools

  @type print_opts :: [
          prompt: String.t(),
          model: Model.t(),
          cwd: String.t(),
          tools: [Tool.t()],
          transport: module(),
          system_prompt: String.t() | nil,
          resource_loader: ResourceLoader.t()
        ]

  @doc """
  Non-interactive single-shot run. Streams text and tool-event markers
  to stdout, returns the stop reason.

  Required: `:prompt`, `:model`. Returns `{:ok, reason}` for a clean
  stop or `{:error, reason}` for `:error`/`:aborted`.
  """
  @spec run_print(print_opts()) :: {:ok, atom()} | {:error, atom()}
  def run_print(opts) when is_list(opts), do: Print.run(opts)

  @doc """
  The seven built-in tools (read/write/edit/ls/bash/grep/find),
  each rooted at `cwd`.
  Used by Print mode and the TUI's Interactive mode so they present
  an identical tool surface to the agent.
  """
  @spec default_tools(String.t()) :: [Tool.t()]
  def default_tools(cwd) when is_binary(cwd) do
    [
      Tools.Read.tool(cwd),
      Tools.Write.tool(cwd),
      Tools.Edit.tool(cwd),
      Tools.Ls.tool(cwd),
      Tools.Bash.tool(cwd),
      Tools.Grep.tool(cwd),
      Tools.Find.tool(cwd)
    ]
  end
end
