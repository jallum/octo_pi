defmodule OctoPi.Coder.Extensions.Commands do
  @moduledoc """
  Registers built-in slash commands for the current session.

  Commands:
    /commands [source]   — list all available commands, optionally filtered
                           by source.
    /compact [text]      — compact the session context. Optional free-text is
                           passed as `custom_instructions` to the summarization
                           LLM.
    /tree <id> [options] — navigate the session tree to entry `<id>`.

  ## /tree syntax

      /tree <entry_id>
      /tree <entry_id> --summarize
      /tree <entry_id> --summarize <custom_instructions>

  The three forms map to `user_wants_summary: :no`, `:yes`, and
  `{:yes, custom_instructions}` respectively, mirroring the three-way result
  of the `SummarizePrompt` component (G5c).

  Ported from `examples/extensions/commands.ts` and
  `src/modes/interactive/interactive-mode.ts` (compact + tree handlers).
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    {:ok, api} =
      API.register_command(api, "commands", %{
        description: "List available slash commands",
        handler: fn args, _ctx -> list_commands(api, String.trim(args)) end
      })

    {:ok, api} =
      API.register_command(api, "compact", %{
        description: "Compact the session context",
        handler: fn args, _ctx -> do_compact(api, String.trim(args)) end
      })

    API.register_command(api, "tree", %{
      description: "Navigate to a session entry (/tree <id> [--summarize [instructions]])",
      handler: fn args, _ctx -> do_tree(api, String.trim(args)) end
    })
  end

  defp list_commands(api, ""), do: api.get_commands.()

  defp list_commands(api, source) do
    Enum.filter(api.get_commands.(), fn c -> Map.get(c, :source) == source end)
  end

  defp do_compact(api, ""), do: api.compact.([])

  defp do_compact(api, instructions), do: api.compact.(custom_instructions: instructions)

  defp do_tree(_api, ""), do: {:error, "usage: /tree <entry_id> [--summarize [instructions]]"}

  defp do_tree(api, args) do
    {entry_id, user_wants_summary} = parse_tree_args(args)
    api.navigate_tree.(entry_id: entry_id, user_wants_summary: user_wants_summary)
  end

  @doc false
  @spec parse_tree_args(String.t()) ::
          {String.t(), :no | :yes | {:yes, String.t()}}
  def parse_tree_args(args) do
    case String.split(args, ~r/\s+--summarize\s*/, parts: 2) do
      [entry_id] ->
        {String.trim(entry_id), :no}

      [entry_id, ""] ->
        {String.trim(entry_id), :yes}

      [entry_id, instructions] ->
        {String.trim(entry_id), {:yes, String.trim(instructions)}}
    end
  end
end
