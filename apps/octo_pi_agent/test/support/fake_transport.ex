defmodule OctoPi.Agent.TestSupport.FakeTransport do
  @moduledoc """
  Test transport. Yields canned `OctoPi.AI.Event` streams, one
  scripted turn per `stream/3` call.

  The script lives in an `Agent` process started on demand under the
  supervision tree of the test run. Tests are `async: false` so a
  single global script works — no per-session plumbing.

      FakeTransport.set_script([
        [%Event.Start{...}, %Event.TextDelta{...}, %Event.Done{...}],
        [%Event.Start{...}, %Event.Done{...}]
      ])
  """

  @behaviour OctoPi.Agent.Transport

  @agent_name __MODULE__

  @doc "Install a list of per-turn event lists."
  @spec set_script([[OctoPi.AI.Event.t()]]) :: :ok
  def set_script(turns) when is_list(turns) do
    ensure_agent()
    Agent.update(@agent_name, fn _ -> turns end)
    :ok
  end

  @doc "Clear the current script (call from `on_exit`)."
  @spec clear() :: :ok
  def clear do
    if Process.whereis(@agent_name), do: Agent.stop(@agent_name)
    :ok
  end

  @impl true
  def stream(_model, _context, _opts) do
    case Agent.get_and_update(@agent_name, fn
           [] -> {:empty, []}
           [head | rest] -> {head, rest}
         end) do
      :empty -> raise "FakeTransport: script exhausted"
      turn -> turn
    end
  end

  defp ensure_agent do
    case Agent.start(fn -> [] end, name: @agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
