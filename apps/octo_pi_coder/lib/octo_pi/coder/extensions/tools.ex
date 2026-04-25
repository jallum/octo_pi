defmodule OctoPi.Coder.Extensions.Tools do
  @moduledoc """
  Provides a /tools command that lists all available tools with their enabled/disabled status.
  Tool selection state is synced on session_start and session_tree events.

  Diverges from tools.ts: the interactive TUI widget and branch-entry persistence are
  not ported (no ctx.sessionManager.getBranch() or ctx.ui.custom equivalent). The /tools
  command returns a status list instead of opening an interactive selector.
  Ported from examples/extensions/tools.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    {:ok, api} = API.on(api, :session_start, fn _event, _ctx -> sync_state(api, state) end)
    {:ok, api} = API.on(api, :session_tree, fn _event, _ctx -> sync_state(api, state) end)

    API.register_command(api, "tools", %{
      description: "List and manage tools (enabled/disabled)",
      handler: fn _args, _ctx -> list_tools(api, state) end
    })
  end

  defp sync_state(api, state) do
    active_names = MapSet.new(api.get_active_tools.(), & &1.name)
    Agent.update(state, fn s -> %{s | enabled_tools: active_names} end)
    :ok
  end

  defp list_tools(api, state) do
    enabled = Agent.get(state, & &1.enabled_tools)

    Enum.map(api.get_all_tools.(), fn tool -> Map.put(tool, :enabled, MapSet.member?(enabled, tool.name)) end)
  end
end
