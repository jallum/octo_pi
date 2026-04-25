defmodule OctoPi.Coder.Extensions.CustomHeader do
  @moduledoc """
  Sets a custom header component on session start.
  Provides /builtin-header command to restore the built-in header.

  Passes a render fn `(width :: integer -> [String.t()])` to `ctx.ui.set_header`.
  The pi mascot TUI widget is not ported; the render fn returns a plain title line.
  Ported from examples/extensions/custom-header.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t()) :: {:ok, API.t()}
  def init(api) do
    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> on_session_start(ctx) end)

    API.register_command(api, "builtin-header", %{
      description: "Restore built-in header with keybinding hints",
      handler: fn _args, ctx -> restore_header(ctx) end
    })
  end

  defp on_session_start(%{has_ui?: true, ui: ui}) do
    ui.set_header.(fn width -> [String.slice("octo_pi", 0, width)] end)
  end

  defp on_session_start(_ctx), do: :ok

  defp restore_header(%{has_ui?: true, ui: ui}) do
    ui.set_header.(nil)
    ui.notify.("Built-in header restored")
  end

  defp restore_header(_ctx), do: :ok
end
