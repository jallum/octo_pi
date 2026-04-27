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
  alias OctoPi.Coder.Compaction.{BranchSummarization, BranchSummaryResult, Preparation, Result, Settings, TreePreparation}
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
  Build the LLM-ready session context from the held `SessionManager`'s
  current branch. Pure read-only delegate to
  `SessionManager.build_session_context/2` (B6) — no extension dispatch,
  no state mutation. Used by the agent run-process to assemble each
  turn's prompt with post-compaction kept-window + synthetic summary.
  """
  @spec build_session_context(GenServer.server()) ::
          %{messages: [term()], thinking_level: String.t(),
            model: %{provider: String.t(), model_id: String.t()} | nil}
  def build_session_context(server), do: GenServer.call(server, :build_session_context)

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

  @doc """
  Fork the current session into a new session file.

  Sequence:

    1. Emit `:session_before_fork` via `Dispatcher.halt_on_result/3`.
       - `{:cancel, reason}` → `{:cancel, reason}`; no file is written.
       - `:ok` → call `SessionManager.fork/4`.

  Options:
    * `:target_cwd`  — working directory for the forked session (required)
    * `:target_dir`  — directory where the new session file is written (required)
    * `:id`          — explicit session id for the fork
    * `:timestamp`   — explicit ISO-8601 timestamp for the fork

  Returns:
    * `{:ok, %SessionManager{}}` on success
    * `{:cancel, reason}` when an extension vetoes the fork
    * `{:error, reason}` when the underlying fork fails
  """
  @type fork_result ::
          {:ok, SessionManager.t()}
          | {:cancel, term()}
          | {:error, :enoent | :empty | :missing_header | :no_session_file}

  @spec fork(GenServer.server(), keyword()) :: fork_result()
  def fork(server, opts),
    do: GenServer.call(server, {:fork, opts}, :infinity)

  @doc """
  Navigate the session tree to `target_id`.

  Sequence:

    1. No-op when `target_id == current_leaf_id` → `{:ok, nil}`.
    2. Build `%TreePreparation{}` from the current and target positions.
    3. Emit `:session_before_tree` via `Dispatcher.halt_on_result/3`.
       - `{:cancel, reason}` → `{:cancel, reason}`; session unchanged.
       - `{:override, %BranchSummaryResult{}}` → use extension summary
         (only honored when `user_wants_summary != :no`).
    4. If no override and `user_wants_summary != :no`, call
       `BranchSummarization.generate/2`.
    5. Update `session_manager.leaf_id` to the new position; when a
       summary was produced, append a `BranchSummary` entry at the
       navigation target first.

  Options:
    * `:target_id`          — (required) entry id to navigate to
    * `:user_wants_summary` — `:no | :yes | {:yes, instructions}`
      (default `:no`)
    * `:model`              — `%OctoPi.AI.Model{}` (required when summarizing)
    * `:api_key`, `:headers`— forwarded to the summarization producer
    * `:producer`           — test injection for `BranchSummarization.generate/2`

  Returns:
    * `{:ok, %BranchSummaryResult{} | nil}` on success
    * `{:cancel, reason}` when an extension vetoes
    * `{:error, :not_found}` when `target_id` is not in the session
    * `{:error, :no_model}` when summarization required but no model given
    * `{:error, term()}` on LLM failure
  """
  @type navigate_tree_result ::
          {:ok, BranchSummaryResult.t() | nil}
          | {:cancel, term()}
          | {:error, :not_found | :no_model | term()}

  @spec navigate_tree(GenServer.server(), keyword()) :: navigate_tree_result()
  def navigate_tree(server, opts),
    do: GenServer.call(server, {:navigate_tree, opts}, :infinity)

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
    agent_pid = Keyword.get(opts, :agent_pid)

    if agent_pid, do: OctoPi.Agent.subscribe(agent_pid, self(), :async)

    state = %State{
      extensions: extensions,
      session_manager: session_manager,
      store_pid: store_pid,
      agent_pid: agent_pid,
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

  def handle_call(:build_session_context, _from, state),
    do: {:reply, SessionManager.build_session_context(state.session_manager), state}

  def handle_call({:add_entry, entry, opts}, _from, state) do
    forward_opts = Keyword.put(opts, :store, state.store_pid)
    {sm, id} = SessionManager.add_entry(state.session_manager, entry, forward_opts)
    {:reply, {:ok, id}, %{state | session_manager: sm}}
  end

  def handle_call({:compact, opts}, _from, state) do
    {:reply, do_compact(state, opts), state}
  end

  def handle_call({:fork, opts}, _from, state) do
    {:reply, do_fork(state, opts), state}
  end

  def handle_call({:navigate_tree, opts}, _from, state) do
    case do_navigate_tree(state, opts) do
      {:ok, summary, old_leaf_id, new_sm} ->
        ctx =
          %Context{cwd: new_sm.cwd}
          |> Context.bind_session_manager(fn -> new_sm end)

        tree_event = Event.new(:session_tree, %{
          new_leaf_id: new_sm.leaf_id,
          old_leaf_id: old_leaf_id
        })

        Dispatcher.emit(state.extensions, tree_event, ctx)
        {:reply, {:ok, summary}, %{state | session_manager: new_sm}}

      other ->
        {:reply, other, state}
    end
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

  # ---- fork ----------------------------------------------------------------

  defp do_fork(%State{} = state, opts) do
    source_path = state.session_manager.session_file

    if source_path == nil do
      {:error, :no_session_file}
    else
      ctx =
        %Context{cwd: state.session_manager.cwd}
        |> Context.bind_session_manager(fn -> state.session_manager end)

      leaf_id = SessionManager.get_leaf_entry_id(state.session_manager)
      event = Event.new(:session_before_fork, %{entry_id: leaf_id})

      case Dispatcher.halt_on_result(state.extensions, event, ctx) do
        {:cancel, reason} ->
          {:cancel, reason}

        :ok ->
          target_cwd = Keyword.fetch!(opts, :target_cwd)
          target_dir = Keyword.fetch!(opts, :target_dir)
          fork_opts = Keyword.take(opts, [:id, :timestamp])
          SessionManager.fork(source_path, target_cwd, target_dir, fork_opts)
      end
    end
  end

  # ---- navigate_tree -------------------------------------------------------

  defp do_navigate_tree(%State{} = state, opts) do
    target_id = Keyword.fetch!(opts, :target_id)
    old_leaf_id = SessionManager.get_leaf_entry_id(state.session_manager)

    if target_id == old_leaf_id do
      {:ok, nil, old_leaf_id, state.session_manager}
    else
      case SessionManager.get_entry(state.session_manager, target_id) do
        nil ->
          {:error, :not_found}

        target_entry ->
          {entries_to_summarize, common_ancestor_id} =
            SessionManager.collect_entries_for_branch_summary(
              state.session_manager,
              old_leaf_id,
              target_id
            )

          user_wants_summary = Keyword.get(opts, :user_wants_summary, :no)

          prep = %TreePreparation{
            target_id: target_id,
            old_leaf_id: old_leaf_id,
            common_ancestor_id: common_ancestor_id,
            entries_to_summarize: entries_to_summarize,
            user_wants_summary: user_wants_summary
          }

          ctx =
            %Context{cwd: state.session_manager.cwd}
            |> Context.bind_session_manager(fn -> state.session_manager end)

          event = Event.new(:session_before_tree, %{preparation: prep})

          case Dispatcher.halt_on_result(state.extensions, event, ctx) do
            {:cancel, reason} ->
              {:cancel, reason}

            {:override, %BranchSummaryResult{} = ext_result} when user_wants_summary != :no ->
              new_sm =
                branch_with_or_without_summary(
                  state.session_manager,
                  target_entry,
                  target_id,
                  old_leaf_id,
                  ext_result,
                  true,
                  state.store_pid
                )

              {:ok, ext_result, old_leaf_id, new_sm}

            :ok ->
              run_default_navigate(state, target_entry, target_id, old_leaf_id, entries_to_summarize, user_wants_summary, opts)

            {:override, _ignored} ->
              run_default_navigate(state, target_entry, target_id, old_leaf_id, entries_to_summarize, user_wants_summary, opts)
          end
      end
    end
  end

  defp run_default_navigate(state, target_entry, target_id, old_leaf_id, entries_to_summarize, user_wants_summary, opts) do
    if user_wants_summary == :no or entries_to_summarize == [] do
      new_sm = set_new_leaf(state.session_manager, target_entry, target_id)
      {:ok, nil, old_leaf_id, new_sm}
    else
      model = Keyword.get(opts, :model)

      if model == nil do
        {:error, :no_model}
      else
        generate_opts = build_summary_opts(model, user_wants_summary, opts)

        case BranchSummarization.generate(entries_to_summarize, generate_opts) do
          {:ok, %BranchSummaryResult{} = result} ->
            new_sm =
              branch_with_or_without_summary(
                state.session_manager,
                target_entry,
                target_id,
                old_leaf_id,
                result,
                false,
                state.store_pid
              )

            {:ok, result, old_leaf_id, new_sm}

          :aborted ->
            {:cancel, :aborted}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  defp build_summary_opts(model, user_wants_summary, opts) do
    base = [
      model: model,
      api_key: Keyword.get(opts, :api_key),
      headers: Keyword.get(opts, :headers)
    ]

    base = case Keyword.get(opts, :producer) do
      nil -> base
      producer -> [{:producer, producer} | base]
    end

    case user_wants_summary do
      :yes -> base
      {:yes, instructions} -> [{:custom_instructions, instructions} | base]
    end
  end

  defp branch_with_or_without_summary(sm, target_entry, target_id, old_leaf_id, summary_result, from_hook, store_pid) do
    new_leaf_id = compute_new_leaf_id(target_entry, target_id)
    sm = %{sm | leaf_id: new_leaf_id}

    from_id = old_leaf_id || "root"
    details = %{
      "readFiles" => summary_result.read_files,
      "modifiedFiles" => summary_result.modified_files
    }

    entry = %Entry.BranchSummary{
      id: nil,
      timestamp: nil,
      from_id: from_id,
      summary: summary_result.summary,
      from_hook: from_hook,
      details: details
    }

    {new_sm, _id} = SessionManager.add_entry(sm, entry, store: store_pid)
    new_sm
  end

  defp set_new_leaf(sm, target_entry, target_id) do
    %{sm | leaf_id: compute_new_leaf_id(target_entry, target_id)}
  end

  defp compute_new_leaf_id(%Entry.Message{message: %{"role" => "user"}, parent_id: pid}, _target_id),
    do: pid

  defp compute_new_leaf_id(_entry, target_id), do: target_id

  # ---- agent event handling ----

  @impl true
  def handle_info(
        {:octo_pi_agent_event, %OctoPi.Agent.Event.CompactionRequested{ref: ref, opts: opts}},
        %State{agent_pid: agent_pid} = state
      ) do
    path_entries = SessionManager.get_branch(state.session_manager)
    settings = state.settings_provider.()

    case Preparation.prepare(path_entries, settings) do
      nil ->
        OctoPi.Agent.compaction_response(agent_pid, ref, {:error, :nothing_to_compact})
        {:noreply, state}

      %Preparation{} = prep ->
        ctx =
          %Context{cwd: state.session_manager.cwd}
          |> Context.bind_session_manager(fn -> state.session_manager end)

        before_event =
          Event.new(:session_before_compact, %{
            preparation: prep,
            custom_instructions: Keyword.get(opts, :custom_instructions)
          })

        case Dispatcher.halt_on_result(state.extensions, before_event, ctx) do
          {:cancel, reason} ->
            OctoPi.Agent.compaction_response(agent_pid, ref, {:cancel, reason})
            {:noreply, state}

          {:override, %Result{} = result} ->
            session_pid = self()
            extensions = state.extensions
            spawn(fn -> finish_compaction(session_pid, agent_pid, ref, result, true, extensions) end)
            {:noreply, state}

          :ok ->
            case state.model_provider.() do
              nil ->
                OctoPi.Agent.compaction_response(agent_pid, ref, {:error, :no_model})
                {:noreply, state}

              model ->
                session_pid = self()
                extensions = state.extensions

                spawn(fn ->
                  case Compaction.compact(prep, model, opts) do
                    {:ok, %Result{} = result} ->
                      finish_compaction(session_pid, agent_pid, ref, result, false, extensions)

                    {:error, reason} ->
                      OctoPi.Agent.compaction_response(agent_pid, ref, {:error, reason})
                  end
                end)

                {:noreply, state}
            end
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_compaction(session_pid, agent_pid, ref, %Result{} = result, from_ext?, extensions) do
    entry = %Entry.Compaction{
      id: nil,
      timestamp: nil,
      summary: result.summary,
      first_kept_entry_id: result.first_kept_entry_id,
      tokens_before: result.tokens_before,
      from_hook: if(from_ext?, do: true, else: nil),
      details: result.details
    }

    {:ok, id} = add_entry(session_pid, entry)
    sm = get_session_manager(session_pid)
    stored = Map.fetch!(sm.by_id, id)
    ctx = %Context{cwd: sm.cwd} |> Context.bind_session_manager(fn -> sm end)
    Dispatcher.emit(extensions, Event.new(:session_compact, %{compaction_entry: stored, from_extension?: from_ext?}), ctx)

    OctoPi.Agent.compaction_response(agent_pid, ref, {:ok, %{
      summary: result.summary,
      first_kept_entry_id: result.first_kept_entry_id,
      tokens_before: result.tokens_before,
      details: result.details,
      from_extension?: from_ext?
    }})
  end
end
