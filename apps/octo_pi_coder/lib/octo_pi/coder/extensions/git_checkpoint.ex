defmodule OctoPi.Coder.Extensions.GitCheckpoint do
  @moduledoc """
  Creates git stash checkpoints at each turn for /fork state restoration.

  Checkpoints are keyed by the session leaf entry ID (from ctx.get_leaf_entry_id),
  matching the upstream git-checkpoint.ts that uses ctx.sessionManager.getLeafEntry().
  Ported from examples/extensions/git-checkpoint.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, checkpoints) do
    {:ok, api} = API.on(api, :turn_start, fn _event, ctx -> on_turn_start(api, ctx, checkpoints) end)
    {:ok, api} = API.on(api, :session_before_fork, fn event, ctx -> on_fork(api, event, ctx, checkpoints) end)
    {:ok, api} = API.on(api, :agent_end, fn _event, _ctx -> on_agent_end(checkpoints) end)
    {:ok, api}
  end

  defp on_turn_start(api, ctx, checkpoints) do
    %{stdout: output} = api.exec.("git", ["stash", "create"])
    ref = String.trim(output)
    entry_id = ctx.get_leaf_entry_id.()

    if ref != "" and entry_id != nil do
      Agent.update(checkpoints, &Map.put(&1, entry_id, ref))
    end

    :ok
  end

  defp on_fork(_api, _event, %{has_ui?: false}, _checkpoints), do: nil

  defp on_fork(api, event, %{has_ui?: true, ui: ui}, checkpoints) do
    case Map.get(Agent.get(checkpoints, & &1), event.entry_id) do
      nil ->
        nil

      ref ->
        options = [%{label: "Yes, restore", value: :yes}, %{label: "No, keep current", value: :no}]

        case ui.select.(options, prompt: "Restore code state to last checkpoint?") do
          {:ok, :yes} ->
            api.exec.("git", ["stash", "apply", ref])
            ui.notify.("Code restored to checkpoint")

          _ ->
            nil
        end
    end
  end

  defp on_agent_end(checkpoints) do
    Agent.update(checkpoints, fn _ -> %{} end)
    :ok
  end
end
