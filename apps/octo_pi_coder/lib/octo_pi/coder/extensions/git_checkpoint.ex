defmodule OctoPi.Coder.Extensions.GitCheckpoint do
  @moduledoc """
  Creates git stash checkpoints at each turn for /fork state restoration.

  Diverges from git-checkpoint.ts: ctx.sessionManager.getLeafEntry() is not available;
  checkpoints are keyed by a monotonic turn counter instead of session entry IDs.
  Ported from examples/extensions/git-checkpoint.ts.
  """

  alias OctoPi.Coder.Extension.API

  @spec init(API.t(), pid()) :: {:ok, API.t()}
  def init(api, checkpoints) do
    {:ok, api} = API.on(api, :turn_start, fn _event, _ctx -> on_turn_start(api, checkpoints) end)
    {:ok, api} = API.on(api, :session_before_fork, fn event, ctx -> on_fork(api, event, ctx, checkpoints) end)
    {:ok, api} = API.on(api, :agent_end, fn _event, _ctx -> on_agent_end(checkpoints) end)
    {:ok, api}
  end

  defp on_turn_start(api, checkpoints) do
    %{stdout: output} = api.exec.("git", ["stash", "create"])
    ref = String.trim(output)

    if ref != "" do
      turn =
        Agent.get_and_update(checkpoints, fn cp ->
          turn = map_size(cp) + 1
          {turn, Map.put(cp, turn, ref)}
        end)

      turn
    end

    :ok
  end

  defp on_fork(_api, _event, %{has_ui?: false}, _checkpoints), do: nil

  defp on_fork(api, _event, %{has_ui?: true, ui: ui}, checkpoints) do
    case latest_checkpoint(checkpoints) do
      nil ->
        nil

      ref ->
        prompt = "Restore code state to last checkpoint?"
        options = [%{label: "Yes, restore", value: :yes}, %{label: "No, keep current", value: :no}]

        case ui.select.(options, prompt: prompt) do
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

  defp latest_checkpoint(checkpoints) do
    cp = Agent.get(checkpoints, & &1)

    if map_size(cp) == 0 do
      nil
    else
      cp |> Map.keys() |> Enum.max() |> then(&Map.get(cp, &1))
    end
  end
end
