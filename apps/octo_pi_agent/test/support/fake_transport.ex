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
    Agent.update(@agent_name, &Map.put(&1, :script, turns))
    :ok
  end

  @doc "Clear the current script (call from `on_exit`)."
  @spec clear() :: :ok
  def clear do
    if Process.whereis(@agent_name), do: Agent.stop(@agent_name)
    :ok
  end

  @doc """
  Block the next `stream/3` call until `release_gate/0` is called.
  The stream Task registers its own pid atomically when it picks up the
  pending gate.  Call `set_gate/0` before prompting, assert the busy
  error, then call `release_gate/0` to unblock the Task.
  """
  @spec set_gate() :: :ok
  def set_gate do
    ensure_agent()
    Agent.update(@agent_name, &Map.put(&1, :gate, :pending))
    :ok
  end

  @spec release_gate() :: :ok
  def release_gate do
    if Process.whereis(@agent_name) do
      case Agent.get_and_update(@agent_name, fn state ->
             {Map.get(state, :gate), Map.delete(state, :gate)}
           end) do
        pid when is_pid(pid) -> send(pid, :gate_released)
        _ -> :ok
      end
    end

    :ok
  end

  @impl true
  def stream(_model, _context, _opts) do
    ensure_agent()
    worker = self()

    # Atomically: pop the next turn and, if a gate is pending, register
    # this Worker Task pid so release_gate/0 can unblock us.
    {needs_gate, turn} =
      Agent.get_and_update(@agent_name, fn state ->
        script = Map.get(state, :script, [])
        {turn_or_empty, new_script} =
          case script do
            [] -> {:empty, []}
            [h | t] -> {h, t}
          end

        new_state =
          case Map.get(state, :gate) do
            :pending -> %{state | script: new_script, gate: worker}
            _ -> %{state | script: new_script}
          end

        gate_active = Map.get(state, :gate) == :pending
        {{gate_active, turn_or_empty}, new_state}
      end)

    if needs_gate do
      receive do
        :gate_released -> :ok
      after
        5_000 -> raise "FakeTransport: gate never released"
      end
    end

    case turn do
      :empty -> raise "FakeTransport: script exhausted"
      turn -> turn
    end
  end

  defp ensure_agent do
    case Agent.start(fn -> %{script: []} end, name: @agent_name) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
