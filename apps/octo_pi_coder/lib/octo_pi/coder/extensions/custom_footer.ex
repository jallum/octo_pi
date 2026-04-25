defmodule OctoPi.Coder.Extensions.CustomFooter do
  @moduledoc """
  Toggles a custom footer component via /footer command.

  Passes a render fn `(width :: integer -> [String.t()])` to `ctx.ui.set_footer`.
  ctx.get_branch is available; live token stats and branch data (footerData) are
  deferred to opi-rcg.9.
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

    if enabled do
      ui.set_footer.(nil)
      ui.notify.("Default footer restored")
    else
      ui.set_footer.(fn _width -> ["custom footer"] end)
      ui.notify.("Custom footer enabled")
    end
  end

  defp toggle_footer(_ctx, _state), do: :ok
end
