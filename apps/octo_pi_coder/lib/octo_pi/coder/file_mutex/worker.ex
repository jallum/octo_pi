defmodule OctoPi.Coder.FileMutex.Worker do
  @moduledoc false

  use GenServer, restart: :temporary

  @default_idle_timeout 5_000

  def start_link(path) when is_binary(path) do
    GenServer.start_link(__MODULE__, path, name: via(path))
  end

  defp via(path), do: {:via, Registry, {OctoPi.Coder.FileMutex.Registry, path}}

  @impl true
  def init(_path) do
    {:ok, %{}, idle_timeout()}
  end

  @impl true
  def handle_call({:run, fun}, _from, state) do
    result =
      try do
        {:ok, fun.()}
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      catch
        kind, reason -> {:caught, kind, reason, __STACKTRACE__}
      end

    {:reply, result, state, idle_timeout()}
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}

  defp idle_timeout do
    Application.get_env(:octo_pi_coder, :file_mutex_idle_timeout) || @default_idle_timeout
  end
end
