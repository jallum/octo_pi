defmodule OctoPi.Coder.Session do
  @moduledoc """
  Per-session orchestrator process. Holds the loaded extension list,
  the in-memory `SessionManager` tree, the `SessionStore` writer pid,
  and provider closures for the current model and compaction settings.

  This is the Elixir analogue of upstream `AgentSession`
  (`tmp/pi-mono/.../core/agent-session.ts`) at the level the coder app
  needs — a single point of contact for orchestration calls
  (`compact`, `navigate_tree`, `fork`, ...) so each one has stable
  state to read and a single writer that keeps the in-memory DAG and
  the on-disk JSONL in lockstep.

  The public surface is the idiomatic Elixir one — `compact/2`,
  `add_entry/3`, `state/1`, etc. The bridge into the extension API
  (a closure map per `Extension.API.bind_core/2`) is built inside
  `Extension.Loader.load_for_session/2` and is not exposed here.
  """

  use GenServer, restart: :temporary

  alias OctoPi.Coder.Compaction
  alias OctoPi.Coder.Compaction.{Preparation, Result, Settings}
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.{Context, Dispatcher, Event}
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager

  @typedoc "Optional providers default to closures returning sensible nils / defaults."
  @type model_provider :: (-> term() | nil)
  @type settings_provider :: (-> Settings.t())

  @type state :: %__MODULE__.State{
          extensions: [Extension.t()],
          session_manager: SessionManager.t(),
          store_pid: pid(),
          agent_pid: pid() | nil,
          model_provider: model_provider(),
          settings_provider: settings_provider()
        }

  defmodule State do
    @moduledoc false

    @enforce_keys [:extensions, :session_manager, :store_pid, :model_provider, :settings_provider]
    defstruct [
      :extensions,
      :session_manager,
      :store_pid,
      :agent_pid,
      :model_provider,
      :settings_provider
    ]
  end

  @type start_opt ::
          {:extensions, [Extension.t()]}
          | {:session_manager, SessionManager.t()}
          | {:store_pid, pid()}
          | {:agent_pid, pid() | nil}
          | {:model_provider, OctoPi.Coder.Session.model_provider()}
          | {:settings_provider, OctoPi.Coder.Session.settings_provider()}
          | {:name, GenServer.name()}

  @doc """
  Start a session under `OctoPi.Coder.Session.Supervisor` (DynamicSupervisor).
  Use this from production callers; tests typically prefer `start_link/1`
  directly with `start_supervised!` so the test owns the lifecycle.
  """
  @spec start_supervised([start_opt()]) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts) do
    DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, opts})
  end

  @spec start_link([start_opt()]) :: GenServer.on_start()
  def start_link(opts) do
    # Validate required opts at the call site so a KeyError surfaces to
    # the caller rather than as a `{:EXIT, ...}` from a doomed GenServer.
    _ = Keyword.fetch!(opts, :extensions)
    _ = Keyword.fetch!(opts, :session_manager)
    _ = Keyword.fetch!(opts, :store_pid)

    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @spec state(GenServer.server()) :: state()
  def state(server), do: GenServer.call(server, :state)

  @spec get_session_manager(GenServer.server()) :: SessionManager.t()
  def get_session_manager(server), do: GenServer.call(server, :get_session_manager)

  @spec get_extensions(GenServer.server()) :: [Extension.t()]
  def get_extensions(server), do: GenServer.call(server, :get_extensions)

  @doc """
  Append an entry to the session. Atomic across the in-memory
  `SessionManager` and the on-disk `SessionStore` (delegates to
  `SessionManager.add_entry/3` with `:store` set to the held pid).

  Options forwarded to `SessionManager.add_entry/3`:

    * `:id` — explicit id (skips generation).
    * `:timestamp` — explicit ISO-8601 timestamp.

  Returns `{:ok, entry_id}`. Errors from the underlying store surface
  as a GenServer crash today; if a softer contract is needed, layer
  it on once a real failure mode shows up.
  """
  @spec add_entry(GenServer.server(), Entry.t(), keyword()) :: {:ok, String.t()}
  def add_entry(server, entry, opts \\ []),
    do: GenServer.call(server, {:add_entry, entry, opts})

  @doc """
  Run the compaction orchestrator. Port of upstream `AgentSession.compact`
  (`tmp/pi-mono/.../core/agent-session.ts:1605`).

  Sequence:

    1. Build a `%Compaction.Preparation{}` from the current branch and
       the held compaction settings.
    2. Emit `:session_before_compact` via `Dispatcher.halt_on_result/3`.
       Honor:
       - `{:cancel, reason}` → reply `{:cancel, reason}`; no LLM call.
       - `{:override, %Result{}}` → reply `{:ok, result, from_extension?: true}`
         (callers persist with `from_hook?: true` per E5b/.25).
    3. Otherwise call `Compaction.compact/2` with the held model.

  Persistence + `:session_compact` emit are scoped to E5b (.25); this
  function only computes and returns the result. Callers persist.

  Options passed through to the LLM path: `:custom_instructions`,
  `:thinking_level`, `:api_key`, `:headers`, `:producer`.
  """
  @type compact_result ::
          {:ok, %{result: Result.t(), from_extension?: boolean()}}
          | {:cancel, term()}
          | {:error, :nothing_to_compact | :no_model | term()}

  @spec compact(GenServer.server(), keyword()) :: compact_result()
  def compact(server, opts \\ []),
    do: GenServer.call(server, {:compact, opts}, :infinity)

  @doc false
  # Internal: closure map for `Extension.API.bind_core/2`. Only the
  # actions this Session actually implements are bound — unimplemented
  # ones stay as the raise-on-call stubs from `API.new/1`, which is
  # exactly the right contract ("not bound — call bind_core first" or
  # not implemented at all is the same observable outcome at the API
  # surface). Used by `Extension.Loader.load_for_session/2`.
  @spec __action_closures__(GenServer.server()) :: map()
  def __action_closures__(server) do
    %{
      append_entry: fn entry -> add_entry(server, entry) end,
      compact: fn opts -> compact(server, opts) end
    }
  end

  # ---- callbacks ----

  @impl true
  def init(opts) do
    extensions = Keyword.fetch!(opts, :extensions)
    session_manager = Keyword.fetch!(opts, :session_manager)
    store_pid = Keyword.fetch!(opts, :store_pid)

    state = %State{
      extensions: extensions,
      session_manager: session_manager,
      store_pid: store_pid,
      agent_pid: Keyword.get(opts, :agent_pid),
      model_provider: Keyword.get(opts, :model_provider, fn -> nil end),
      settings_provider: Keyword.get(opts, :settings_provider, &Settings.default/0)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call(:get_session_manager, _from, state),
    do: {:reply, state.session_manager, state}

  def handle_call(:get_extensions, _from, state),
    do: {:reply, state.extensions, state}

  def handle_call({:add_entry, entry, opts}, _from, state) do
    forward_opts = Keyword.put(opts, :store, state.store_pid)
    {sm, id} = SessionManager.add_entry(state.session_manager, entry, forward_opts)
    {:reply, {:ok, id}, %{state | session_manager: sm}}
  end

  def handle_call({:compact, opts}, _from, state) do
    {:reply, do_compact(state, opts), state}
  end

  defp do_compact(%State{} = state, opts) do
    path_entries = SessionManager.get_branch(state.session_manager)
    settings = state.settings_provider.()

    case Preparation.prepare(path_entries, settings) do
      nil ->
        {:error, :nothing_to_compact}

      %Preparation{} = prep ->
        dispatch_compact(state, prep, opts)
    end
  end

  defp dispatch_compact(%State{} = state, prep, opts) do
    ctx =
      %Context{cwd: state.session_manager.cwd}
      |> Context.bind_session_manager(fn -> state.session_manager end)

    event =
      Event.new(:session_before_compact, %{
        preparation: prep,
        custom_instructions: Keyword.get(opts, :custom_instructions)
      })

    case Dispatcher.halt_on_result(state.extensions, event, ctx) do
      {:cancel, reason} ->
        {:cancel, reason}

      {:override, %Result{} = result} ->
        {:ok, %{result: result, from_extension?: true}}

      :ok ->
        run_default_compact(state, prep, opts)
    end
  end

  defp run_default_compact(%State{} = state, prep, opts) do
    case state.model_provider.() do
      nil ->
        {:error, :no_model}

      model ->
        case Compaction.compact(prep, model, opts) do
          {:ok, %Result{} = result} ->
            {:ok, %{result: result, from_extension?: false}}

          {:error, _} = err ->
            err
        end
    end
  end
end
