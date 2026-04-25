defmodule OctoPi.Coder.Extensions.StatusLine do
  @moduledoc """
  Displays turn progress in the status area via ctx.ui.set_status.

  Diverges from status-line.ts: ctx.ui.theme is not available; status text
  uses plain strings without ANSI theming.
  Ported from examples/extensions/status-line.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, state) do
    {:ok, api} = API.on(api, :session_start, fn _event, ctx -> on_session_start(ctx) end)
    {:ok, api} = API.on(api, :turn_start, fn _event, ctx -> on_turn_start(ctx, state) end)
    {:ok, api} = API.on(api, :turn_end, fn _event, ctx -> on_turn_end(ctx, state) end)
    {:ok, api}
  end

  defp on_session_start(%{has_ui?: true, ui: ui}), do: ui.set_status.("Ready")
  defp on_session_start(_ctx), do: :ok

  defp on_turn_start(%{has_ui?: true, ui: ui}, state) do
    turn =
      Agent.get_and_update(state, fn s ->
        n = s.turn_count + 1
        {n, %{s | turn_count: n}}
      end)

    ui.set_status.("Turn #{turn}...")
  end

  defp on_turn_start(_ctx, state) do
    Agent.update(state, fn s -> %{s | turn_count: s.turn_count + 1} end)
    :ok
  end

  defp on_turn_end(%{has_ui?: true, ui: ui}, state) do
    turn = Agent.get(state, & &1.turn_count)
    ui.set_status.("Turn #{turn} complete")
  end

  defp on_turn_end(_ctx, _state), do: :ok
end
