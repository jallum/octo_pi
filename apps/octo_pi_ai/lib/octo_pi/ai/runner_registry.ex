defmodule OctoPi.AI.RunnerRegistry do
  @moduledoc """
  ETS-backed registry mapping *runner instance names* (atoms) to their
  implementing `OctoPi.AI.Runner` modules.

  Owned by a GenServer started under `OctoPi.AI.Application`'s
  supervisor. Writes go through the owner process; reads go straight to
  the public ETS table (read-concurrent).

  Runner apps call `register/2` from their own `Application.start/2`
  callback to announce themselves:

      def start(_, _) do
        OctoPi.AI.RunnerRegistry.register(:anthropic, OctoPi.AI.Runners.Anthropic)
        ...
      end

  `OctoPi.AI.ModelRegistry` consults `list/0` by default to resolve
  runner-name JSON keys to modules; tests can pass an explicit
  `:runners` map to bypass the global registry.
  """

  use GenServer

  @table :octo_pi_runners

  @doc false
  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: __MODULE__)
  end

  @doc """
  Register `module` as the runner for `name`. Overwrites any prior
  registration.
  """
  @spec register(atom(), module()) :: :ok
  def register(name, module) when is_atom(name) and is_atom(module) do
    GenServer.call(__MODULE__, {:register, name, module})
  end

  @doc "Remove a runner registration. Primarily for tests."
  @spec unregister(atom()) :: :ok
  def unregister(name) when is_atom(name) do
    GenServer.call(__MODULE__, {:unregister, name})
  end

  @doc "Module registered for `name`, or `nil`."
  @spec lookup(atom()) :: module() | nil
  def lookup(name) when is_atom(name) do
    case :ets.lookup(@table, name) do
      [{^name, module}] -> module
      [] -> nil
    end
  end

  @doc "Snapshot of all current registrations."
  @spec list() :: %{atom() => module()}
  def list do
    @table |> :ets.tab2list() |> Map.new()
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end

  @impl true
  def handle_call({:register, name, module}, _from, state) do
    :ets.insert(@table, {name, module})
    {:reply, :ok, state}
  end

  def handle_call({:unregister, name}, _from, state) do
    :ets.delete(@table, name)
    {:reply, :ok, state}
  end
end
