defmodule OctoPi.AI.Providers.Anthropic.ToolNames do
  @moduledoc """
  Tool-name casing normalization for the Claude Code OAuth path.

  Anthropic's OAuth session layer expects Claude Code's canonical tool
  names (PascalCase). Callers who register a tool under a different
  casing (e.g. lowercase "read") have it rewritten to "Read" on
  outbound, and rewritten back to "read" on inbound so the caller
  receives the original identifier.

  Matches pi-mono's `anthropic.ts` L67-104:
    - `to_claude_code/1` — case-insensitive lookup in the CC tool list;
      returns CC casing if matched, otherwise the input unchanged.
    - `from_claude_code/2` — reverse lookup against the caller's tool
      list (case-insensitive name match); returns the caller's casing
      or the input unchanged.

  Tools the caller defines that don't match any CC name pass through
  untouched in both directions. This deliberately avoids the old
  `find → Glob` semantic mapping, which broke the round-trip because
  there's no tool named "glob" in the context — see pi-mono's
  `anthropic-tool-name-normalization.test.ts:112-163`.
  """

  alias OctoPi.AI.Tool

  # Canonical Claude Code 2.x tool names.
  # Source: pi-mono anthropic.ts L73-91.
  # To update: https://github.com/badlogic/cchistory
  @claude_code_tools ~w(
    Read
    Write
    Edit
    Bash
    Grep
    Glob
    AskUserQuestion
    EnterPlanMode
    ExitPlanMode
    KillShell
    NotebookEdit
    Skill
    Task
    TaskOutput
    TodoWrite
    WebFetch
    WebSearch
  )

  @lookup Map.new(@claude_code_tools, fn name -> {String.downcase(name), name} end)

  @doc "The frozen list of Claude Code canonical tool names."
  @spec claude_code_tools() :: [String.t()]
  def claude_code_tools, do: @claude_code_tools

  @doc """
  Rewrite a tool name to Claude Code canonical casing if it matches
  one (case-insensitive). Returns the input unchanged otherwise.
  """
  @spec to_claude_code(String.t()) :: String.t()
  def to_claude_code(name) when is_binary(name) do
    Map.get(@lookup, String.downcase(name), name)
  end

  @doc """
  Reverse-rewrite an inbound tool name using the caller's tool list.
  Matches by case-insensitive equality; returns the caller's casing
  on hit, or the input unchanged otherwise.
  """
  @spec from_claude_code(String.t(), [Tool.t()]) :: String.t()
  def from_claude_code(name, tools) when is_binary(name) and is_list(tools) do
    lower = String.downcase(name)

    case Enum.find(tools, fn %Tool{name: n} -> String.downcase(n) == lower end) do
      nil -> name
      %Tool{name: original} -> original
    end
  end
end
