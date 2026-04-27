defmodule OctoPi.Coder.Extensions.Commands do
  @moduledoc """
  Registers built-in slash commands for the current session.

  Commands:
    /commands [source]  — lists all available commands, optionally filtered
                          by source.
    /compact [text]     — compacts the session context. Optional free-text is
                          passed as `custom_instructions` to the summarization
                          LLM.

  Ported from `examples/extensions/commands.ts` and
  `src/modes/interactive/interactive-mode.ts` (compact handler).
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    {:ok, api} =
      API.register_command(api, "commands", %{
        description: "List available slash commands",
        handler: fn args, _ctx -> list_commands(api, String.trim(args)) end
      })

    API.register_command(api, "compact", %{
      description: "Compact the session context",
      handler: fn args, _ctx -> do_compact(api, String.trim(args)) end
    })
  end

  defp list_commands(api, ""), do: api.get_commands.()

  defp list_commands(api, source) do
    Enum.filter(api.get_commands.(), fn c -> Map.get(c, :source) == source end)
  end

  defp do_compact(api, ""), do: api.compact.([])

  defp do_compact(api, instructions),
    do: api.compact.(custom_instructions: instructions)
end
