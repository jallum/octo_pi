defmodule OctoPi.Coder.Extensions.CustomFooter do
  @moduledoc """
  Toggles a custom footer component via /footer command.

  Passes a render fn `(width, footer_data) -> [String.t()]` to `ctx.ui.set_footer`.
  footer_data.get_git_branch.() returns the current branch, and
  footer_data.get_extension_statuses.() returns the extension status map.
  Live branch-change subscriptions (on_branch_change) are stubbed.
  Ported from examples/extensions/custom-footer.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    API.register_command(api, "footer", %{
      description: "Toggle custom footer display",
      handler: fn _args, ctx -> toggle_footer(ctx, state) end
    })
  end

  defp toggle_footer(%{has_ui?: true, ui: ui}, state) do
    enabled = Agent.get_and_update(state, fn s -> {s.enabled, %{s | enabled: !s.enabled}} end)
    do_toggle(enabled, ui)
  end

  defp do_toggle(true, ui) do
    ui.set_footer.(nil)
    ui.notify.("Default footer restored")
  end

  defp do_toggle(false, ui) do
    ui.set_footer.(fn _width, footer_data -> render_footer(footer_data) end)
    ui.notify.("Custom footer enabled")
  end

  defp render_footer(footer_data) do
    branch = footer_data.get_git_branch.()
    statuses = footer_data.get_extension_statuses.()
    branch_part = if branch, do: " (#{branch})", else: ""
    status_part = status_string(statuses)
    ["custom footer#{branch_part}#{status_part}"]
  end

  defp status_string(statuses) when map_size(statuses) == 0, do: ""
  defp status_string(statuses), do: " · " <> Enum.map_join(statuses, ", ", fn {_, v} -> v end)

  defp toggle_footer(_ctx, _state), do: :ok
end
