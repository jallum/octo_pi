defmodule OctoPi.AI.ProviderRegistry do
  @moduledoc """
  ETS-backed registry mapping `api` atoms to their implementing
  `OctoPi.AI.Provider` modules.

  Owned by a GenServer started under `OctoPi.AI.Application`'s
  supervisor. Writes go through the owner process (one writer at a
  time), reads go straight to the public ETS table (read-concurrent).

  Providers call `register/2` from their own
  `Application.start/2` callback to announce themselves:

      def start(_, _) do
        OctoPi.AI.ProviderRegistry.register(:anthropic_messages, __MODULE__)
        ...
      end

  `OctoPi.AI.stream/3` calls `lookup/1` to dispatch by `model.api`.
  """

  use GenServer

  @table :octo_pi_providers

  # --- public API ---

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Register `module` as the implementation for `api`. Overwrites any
  prior registration for the same api.
  """
  @spec register(atom(), module()) :: :ok
  def register(api, module) when is_atom(api) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, api, module})
  end

  @doc """
  Remove an api's registration. Primarily useful in tests.
  """
  @spec unregister(atom()) :: :ok
  def unregister(api) when is_atom(api) do
    GenServer.call(__MODULE__, {:unregister, api})
  end

  @doc """
  Return the module registered for `api`, or `nil` if nothing is
  registered. Reads the ETS table directly — cheap, lock-free.
  """
  @spec lookup(atom()) :: module() | nil
  def lookup(api) when is_atom(api) do
    case :ets.lookup(@table, api) do
      [{^api, module}] -> module
      [] -> nil
    end
  end

  @doc """
  Return a snapshot of all current registrations as a map.
  """
  @spec list() :: %{atom() => module()}
  def list do
    @table |> :ets.tab2list() |> Map.new()
  end

  # --- GenServer callbacks ---

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, api, module}, _from, state) do
    :ets.insert(@table, {api, module})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, api}, _from, state) do
    :ets.delete(@table, api)
    {:reply, :ok, state}
  end
end
