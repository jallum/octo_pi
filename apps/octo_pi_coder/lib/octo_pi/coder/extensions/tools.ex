defmodule OctoPi.Coder.Extensions.Tools do
  @moduledoc """
  Provides a /tools command to enable/disable tools interactively.
  When a UI is available, opens a full-screen tool selector via ctx.ui.custom.
  Falls back to returning a status list when no UI is available.
  Tool selection state is synced on session_start and session_tree events.
  When the entry stream contains a `Session.Entry.Custom` entry with
  `custom_type: "tools_config"`, the most recent one restores the
  previously-enabled set.
  Ported from examples/extensions/tools.ts.
  """

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Session.Entry.Custom, as: CustomEntry

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> sync_state(api, ctx, state) end)
    {:ok, api} = API.on(api, :session_tree, fn _event, ctx -> sync_state(api, ctx, state) end)

    API.register_command(api, "tools", %{
      description: "List and manage tools (enabled/disabled)",
      handler: fn _args, ctx -> handle_command(ctx, api, state) end
    })
  end

  defp handle_command(%{has_ui?: true, ui: ui}, api, state) do
    ui.custom.(fn tui, theme, done -> build_widget(tui, theme, done, api, state) end, [])
  end

  defp handle_command(_ctx, api, state) do
    list_tools(api, state)
  end

  defp build_widget(tui, theme, done, api, state) do
    {:ok, sel} = Agent.start_link(fn -> 0 end)
    all_tools = api.get_all_tools.()

    %{
      render: fn width ->
        render_tool_list(all_tools, Agent.get(state, & &1.enabled_tools), Agent.get(sel, & &1), width, theme)
      end,
      handle_input: fn event -> handle_widget_input(event, sel, all_tools, api, state, done, tui) end
    }
  end

  defp handle_widget_input({:key, %{key: :up}}, sel, _all_tools, _api, _state, _done, tui) do
    Agent.update(sel, fn s -> max(0, s - 1) end)
    tui.request_render.()
  end

  defp handle_widget_input({:key, %{key: :down}}, sel, all_tools, _api, _state, _done, tui) do
    n = length(all_tools)
    Agent.update(sel, fn s -> min(n - 1, s + 1) end)
    tui.request_render.()
  end

  defp handle_widget_input({:key, %{key: :enter}}, sel, all_tools, api, state, _done, tui) do
    idx = Agent.get(sel, & &1)
    tool = Enum.at(all_tools, idx)
    toggle_tool(tool.name, api, state)
    tui.request_render.()
  end

  defp handle_widget_input({:key, %{key: :escape}}, _sel, _all_tools, _api, _state, done, _tui) do
    done.(nil)
  end

  defp handle_widget_input(_event, _sel, _all_tools, _api, _state, _done, _tui), do: :ok

  defp render_tool_list(tools, enabled, selected, _width, theme) do
    header = theme.fg.(:accent, "Tool Configuration")

    items =
      Enum.with_index(tools, fn tool, idx ->
        status = if MapSet.member?(enabled, tool.name), do: "enabled", else: "disabled"
        cursor = if idx == selected, do: "> ", else: "  "
        label = "#{cursor}#{tool.name}: #{status}"
        if idx == selected, do: theme.fg.(:accent, label), else: label
      end)

    [header, ""] ++ items ++ ["", "(↑↓ select, Enter toggle, Esc close)"]
  end

  defp toggle_tool(name, api, state) do
    enabled =
      Agent.get_and_update(state, fn s ->
        new_enabled =
          if MapSet.member?(s.enabled_tools, name),
            do: MapSet.delete(s.enabled_tools, name),
            else: MapSet.put(s.enabled_tools, name)

        {new_enabled, %{s | enabled_tools: new_enabled}}
      end)

    api.set_active_tools.(MapSet.to_list(enabled))

    api.append_entry.(CustomEntry.new("tools_config", %{"enabled_tools" => MapSet.to_list(enabled)}))
  end

  defp sync_state(api, ctx, state) do
    case restore_from_entries(api, ctx, state) do
      :ok -> :ok
      :no_config -> sync_from_active(api, state)
    end
  end

  defp restore_from_entries(api, ctx, state) do
    saved =
      ctx.get_entries.()
      |> Enum.reverse()
      |> Enum.find_value(fn
        %CustomEntry{custom_type: "tools_config", data: %{"enabled_tools" => names}}
        when is_list(names) ->
          names

        _ ->
          nil
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
