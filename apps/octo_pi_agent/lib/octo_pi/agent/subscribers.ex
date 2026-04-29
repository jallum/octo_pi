defmodule OctoPi.Agent.Subscribers do
  @moduledoc """
  Per-loop subscriber list. Uses `Registry` (`:duplicate` keys)
  started by the app supervisor. Each subscriber registers under the
  loop's pid with its `:sync | :async` mode as the value.

  Dispatch order is **registration order within a mode** — `:sync`
  listeners are awaited in order, then `:async` listeners get
  fire-and-forget sends. This is a slight divergence from
  pi-agent-core's single-barrier: we split so a noisy async observer
  can't hold up the loop. Sync listeners still preserve the TS
  barrier for anyone who needs it.
  """

  require Logger

  @registry OctoPi.Agent.Subscribers

  @type mode :: :sync | :async

  @doc """
  Subscribe `listener_pid` to `loop_pid`'s events. Returns an
  unsubscribe function.
  """
  @spec subscribe(pid(), pid(), mode()) :: (-> :ok)
  def subscribe(loop_pid, listener_pid, mode) when mode in [:sync, :async] do
    {:ok, _} = Registry.register(@registry, loop_pid, {listener_pid, mode})

    fn -> unsubscribe(loop_pid, listener_pid) end
  end

  @doc "Remove a listener from a loop."
  @spec unsubscribe(pid(), pid()) :: :ok
  def unsubscribe(loop_pid, listener_pid) do
    Registry.unregister_match(@registry, loop_pid, {listener_pid, :_})
    :ok
  end

  @doc """
  Send `event` to every listener registered for `loop_pid`.
  `:sync` listeners are awaited via `GenServer.call` (5s timeout per
  listener; on timeout we log and continue). `:async` listeners get
  `send/2` and we don't wait.
  """
  @spec dispatch(pid(), term()) :: :ok
  def dispatch(loop_pid, event) do
    Registry.dispatch(@registry, loop_pid, fn entries ->
      {sync, async} =
        Enum.split_with(entries, fn {_pid, {_listener, mode}} -> mode == :sync end)

      Enum.each(sync, fn {_pid, {listener, _mode}} ->
        try do
          GenServer.call(listener, {:octo_pi_agent_event, event}, 5_000)
        catch
          :exit, reason ->
            Logger.warning(
              "[OctoPi.Agent.Subscribers] sync listener #{inspect(listener)} " <>
                "exited during dispatch: #{inspect(reason)}"
            )
        end
      end)

      Enum.each(async, fn {_pid, {listener, _mode}} ->
        send(listener, {:octo_pi_agent_event, event})
      end)
    end)

    :ok
  end

  @doc false
  @spec count(pid()) :: non_neg_integer()
  def count(loop_pid), do: length(Registry.lookup(@registry, loop_pid))
end
