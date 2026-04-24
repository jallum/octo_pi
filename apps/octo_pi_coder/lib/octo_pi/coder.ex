defmodule OctoPi.Coder do
  @moduledoc """
  Coding-agent core: the application layer that composes the
  `OctoPi.Agent` kernel with a JSONL session store, built-in file +
  bash + search tools, and the Print / RPC output modes.

  Public facade is intentionally thin — callers should reach for
  specific submodules (`OctoPi.Coder.SessionStore`,
  `OctoPi.Coder.Tools.*`, `OctoPi.Coder.Modes.Print`,
  `OctoPi.Coder.Modes.Rpc`).
  """

  alias OctoPi.Coder.Tools

  @doc """
  The seven built-in tools (read/write/edit/ls/bash/grep/find),
  each rooted at `cwd` per the session's PathGuard contract.
  Used by Print mode, RPC mode, and the TUI's Interactive mode so
  they present an identical tool surface to the agent.
  """
  @spec default_tools(String.t()) :: [OctoPi.Agent.Tool.t()]
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
