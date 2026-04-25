defmodule OctoPi.Coder.Extensions.CustomHeader do
  @moduledoc """
  Sets a custom header component on session start.
  Provides /builtin-header command to restore the built-in header.

  Diverges from custom-header.ts: the pi mascot TUI widget is not ported;
  the header component is a plain map descriptor.
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
    ui.set_header.(%{type: :custom_header, title: "octo_pi"})
  end

  defp on_session_start(_ctx), do: :ok

  defp restore_header(%{has_ui?: true, ui: ui}) do
    ui.set_header.(nil)
    ui.notify.("Built-in header restored")
  end

  defp restore_header(_ctx), do: :ok
end
