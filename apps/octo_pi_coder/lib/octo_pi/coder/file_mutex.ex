defmodule OctoPi.Coder.FileMutex do
  @moduledoc """
  Per-path serialization of file operations. Spawns one
  `OctoPi.Coder.FileMutex.Worker` GenServer per absolute path,
  lazily under `OctoPi.Coder.FileMutex.Supervisor`, looked up
  through `OctoPi.Coder.FileMutex.Registry`.

  Reads and writes both go through the same lock (matches upstream
  pi-mono's `FileMutationQueue` — simplest correct semantics).

  Workers self-terminate after an idle timeout so we don't
  accumulate GenServers for every file touched during a long-lived
  session.

  ## Usage

      FileMutex.with_lock("/tmp/x.txt", fn ->
        File.write!("/tmp/x.txt", "hi")
      end)
  """

  alias OctoPi.Coder.FileMutex.Worker

  @registry OctoPi.Coder.FileMutex.Registry
  @supervisor OctoPi.Coder.FileMutex.Supervisor
  @start_retries 3

  @doc """
  Acquire the lock for `path`, run `fun`, and release. The lock is
  always released — even if `fun` raises (the exception is
  re-raised to the caller).
  """
  @spec with_lock(Path.t(), (-> term())) :: term()
  def with_lock(path, fun) when is_function(fun, 0) do
    key = Path.expand(path)
    do_with_lock(key, fun, @start_retries)
  end

  defp do_with_lock(_key, _fun, 0) do
    raise RuntimeError, "file mutex worker could not be started / stayed alive long enough"
  end

  defp do_with_lock(key, fun, retries) do
    {:ok, _pid} = ensure_worker(key)

    try do
      case GenServer.call(via(key), {:run, fun}, :infinity) do
        {:ok, value} ->
          value

        {:raised, exception, stacktrace} ->
          reraise exception, stacktrace

        {:caught, kind, reason, stacktrace} ->
          :erlang.raise(kind, reason, stacktrace)
      end
    catch
      # Worker self-terminated between start and our call — retry.
      :exit, {:noproc, _} -> do_with_lock(key, fun, retries - 1)
    end
  end

  defp ensure_worker(key) do
    case DynamicSupervisor.start_child(@supervisor, {Worker, key}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
    end
  end

  defp via(key), do: {:via, Registry, {@registry, key}}
end
