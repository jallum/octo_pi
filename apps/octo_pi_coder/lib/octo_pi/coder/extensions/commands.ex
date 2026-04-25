defmodule OctoPi.Coder.Extensions.Commands do
  @moduledoc """
  Registers a /commands slash command that lists all available commands in the
  current session. Demonstrates api.get_commands.(). Ported from
  examples/extensions/commands.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    API.register_command(api, "commands", %{
      description: "List available slash commands",
      handler: fn args, _ctx -> list_commands(api, String.trim(args)) end
    })
  end

  defp list_commands(api, ""), do: api.get_commands.()

  defp list_commands(api, source) do
    Enum.filter(api.get_commands.(), fn c -> Map.get(c, :source) == source end)
  end
end
