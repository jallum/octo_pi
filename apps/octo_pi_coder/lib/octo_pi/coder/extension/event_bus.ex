defmodule OctoPi.Coder.Extension.EventBus do
  @moduledoc false
  use GenServer

  require Logger

  @type server :: GenServer.server()

  def start_link(opts), do: GenServer.start_link(__MODULE__, %{}, opts)

  @spec emit(server(), String.t(), term()) :: :ok
  def emit(bus, channel, data), do: GenServer.cast(bus, {:emit, channel, data})

  @spec on(server(), String.t(), (term() -> term())) :: (-> :ok)
  def on(bus, channel, handler) when is_function(handler, 1) do
    ref = make_ref()
    GenServer.call(bus, {:on, channel, handler, ref})
    fn -> GenServer.call(bus, {:off, channel, ref}) end
  end

  @spec clear(server()) :: :ok
  def clear(bus), do: GenServer.call(bus, :clear)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:on, channel, handler, ref}, _from, state) do
    subs = Map.get(state, channel, [])
    {:reply, :ok, Map.put(state, channel, subs ++ [{ref, handler}])}
  end

  def handle_call({:off, channel, ref}, _from, state) do
    subs = Map.get(state, channel, []) |> Enum.reject(fn {r, _} -> r == ref end)
    {:reply, :ok, Map.put(state, channel, subs)}
  end

  def handle_call(:clear, _from, _state), do: {:reply, :ok, %{}}

  @impl true
  def handle_cast({:emit, channel, data}, state) do
    for {_ref, handler} <- Map.get(state, channel, []) do
      try do
        handler.(data)
      rescue
        e -> Logger.warning("EventBus handler error on #{channel}: #{Exception.message(e)}")
      end
    end

    {:noreply, state}
  end
end
