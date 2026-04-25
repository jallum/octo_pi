defmodule OctoPi.Coder.Extensions.Tools do
  @moduledoc """
  Provides a /tools command that lists all available tools with their enabled/disabled status.
  Tool selection state is synced on session_start and session_tree events.
  When branch entries contain a tools-config custom entry, it restores from there.

  Diverges from tools.ts: the interactive TUI widget (ctx.ui.custom) is not ported.
  The /tools command returns a status list instead of opening an interactive selector.
  Ported from examples/extensions/tools.ts.
  """

  alias OctoPi.Agent.Message.Custom
  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> sync_state(api, ctx, state) end)
    {:ok, api} = API.on(api, :session_tree, fn _event, ctx -> sync_state(api, ctx, state) end)

    API.register_command(api, "tools", %{
      description: "List and manage tools (enabled/disabled)",
      handler: fn _args, _ctx -> list_tools(api, state) end
    })
  end

  defp sync_state(api, ctx, state) do
    case restore_from_branch(api, ctx, state) do
      :ok -> :ok
      :no_config -> sync_from_active(api, state)
    end
  end

  defp restore_from_branch(api, ctx, state) do
    branch = ctx.get_branch.()

    saved =
      Enum.find_value(Enum.reverse(branch), fn
        %Custom{kind: :tools_config, payload: %{enabled_tools: names}} when is_list(names) -> names
        _ -> nil
      end)

    if saved do
      all_names = MapSet.new(api.get_all_tools.(), & &1.name)
      enabled = saved |> Enum.filter(&MapSet.member?(all_names, &1)) |> MapSet.new()
      Agent.update(state, fn s -> %{s | enabled_tools: enabled} end)
      api.set_active_tools.(MapSet.to_list(enabled))
      :ok
    else
      :no_config
    end
  end

  defp sync_from_active(api, state) do
    active_names = MapSet.new(api.get_active_tools.(), & &1.name)
    Agent.update(state, fn s -> %{s | enabled_tools: active_names} end)
    :ok
  end

  defp list_tools(api, state) do
    enabled = Agent.get(state, & &1.enabled_tools)

    Enum.map(api.get_all_tools.(), fn tool -> Map.put(tool, :enabled, MapSet.member?(enabled, tool.name)) end)
  end
end
