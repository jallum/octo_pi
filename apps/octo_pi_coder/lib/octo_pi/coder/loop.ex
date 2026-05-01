defmodule OctoPi.Coder.Loop do
  @moduledoc """
  Per-loop orchestrator process. Holds the loaded extension list, a
  cached linearization of the current branch (`:path`), and the pid of
  the `OctoPi.Coder.SessionStore` that owns the tree-of-record.

  This is the Elixir analogue of upstream `AgentSession`
  (`tmp/pi-mono/.../core/agent-session.ts`) at the level the coder app
  needs — a single point of contact for orchestration calls
  (`compact`, `navigate_tree`, `fork`, ...) so each one has stable
  state to read.

  ## State model

  After the opi-qy9.1 rebalance the Loop no longer carries the full
  session tree. Its `:path` field is a linearized root→leaf list of
  typed `Entry.t()` — a cache that mirrors the Store's view of the
  active branch. Mutations (append_entry, branch navigation) round-trip
  through the Store; the Loop updates `:path` from the Store's reply
  rather than walking parent pointers locally.

  All public operations are surfaced through `OctoPi.Coder`. The bridge
  into the extension API (a closure map per `Extension.API.bind_core/2`)
  is built inside `Extension.Loader.load_for_session/2` and is not
  exposed here.
  """

  use GenServer, restart: :temporary

  alias OctoPi.Agent.Subscribers
  alias OctoPi.AI.Message.User
  alias OctoPi.Coder.Compaction
  alias OctoPi.Coder.Compaction.BranchSummarization
  alias OctoPi.Coder.Compaction.BranchSummaryResult
  alias OctoPi.Coder.Compaction.Preparation
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Compaction.Tokens
  alias OctoPi.Coder.Compaction.TreePreparation
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Loop
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.MessageWriter
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.SettingsManager

  @typedoc "Optional providers default to closures returning sensible nils / defaults."
  @type model_provider :: (-> term() | nil)

  @type compact_pending ::
          %{
            worker_pid: pid(),
            worker_ref: reference(),
            monitor_ref: reference(),
            source: :manual | :pre_prompt | :mid_run,
            # Continuation describes what to do once compact resolves.
            # `{:reply, from}` for manual; `{:forward_prompt, from, save, send}`
            # for pre-prompt; `{:agent_response, ref}` for mid-run.
            continuation:
              {:reply, GenServer.from()}
              | {:forward_prompt, GenServer.from(), String.t(), String.t()}
              | {:agent_response, reference()}
          }

  @type state :: %__MODULE__.State{
          extensions: [Extension.t()],
          store_pid: SessionStore.t(),
          agent_pid: OctoPi.Agent.t(),
          model_provider: model_provider(),
          settings_manager: pid(),
          compact_pending: compact_pending() | nil
        }

  defmodule State do
    @moduledoc false

    @enforce_keys [:extensions, :store_pid, :agent_pid, :model_provider, :settings_manager]
    defstruct [
      :extensions,
      :store_pid,
      :agent_pid,
      :model_provider,
      :settings_manager,
      compact_pending: nil
    ]
  end

  @type start_opts :: [
          extensions: [Extension.t()],
          store_pid: SessionStore.t(),
          agent_pid: OctoPi.Agent.t(),
          model_provider: Loop.model_provider(),
          settings_manager: pid(),
          name: GenServer.name()
        ]

  @doc """
  Start a loop under `OctoPi.Coder.Loop.Supervisor` (DynamicSupervisor).
  Use this from production callers; tests typically prefer `start_link/1`
  directly with `start_supervised!` so the test owns the lifecycle.
  """
  @spec start_supervised(start_opts()) :: DynamicSupervisor.on_start_child()
  def start_supervised(opts), do: DynamicSupervisor.start_child(__MODULE__.Supervisor, {__MODULE__, opts})

  @spec start_link(start_opts()) :: GenServer.on_start()
  def start_link(opts) do
    # Validate required opts at the call site so a KeyError surfaces to
    # the caller rather than as a `{:EXIT, ...}` from a doomed GenServer.
    _ = Keyword.fetch!(opts, :extensions)
    _ = Keyword.fetch!(opts, :store_pid)
    _ = Keyword.fetch!(opts, :agent_pid)

    {name, opts} = Keyword.pop(opts, :name)

    if name,
      do: GenServer.start_link(__MODULE__, opts, name: name),
      else: GenServer.start_link(__MODULE__, opts)
  end

  @type compact_result ::
          {:ok, %{result: Result.t(), from_extension?: boolean()}}
          | {:cancel, term()}
          | {:error, :nothing_to_compact | :no_model | term()}

  @type fork_result ::
          {:ok, SessionStore.t()}
          | {:cancel, term()}
          | {:error, atom()}

  @type navigate_tree_result ::
          {:ok, BranchSummaryResult.t() | nil}
          | {:cancel, term()}
          | {:error, :not_found | :no_model | term()}

  @doc false
  # Internal: closure map for `Extension.API.bind_core/2`. Only the
  # actions this Loop actually implements are bound — unimplemented
  # ones stay as the raise-on-call stubs from `API.new/1`, which is
  # exactly the right contract ("not bound — call bind_core first" or
  # not implemented at all is the same observable outcome at the API
  # surface). Used by `Extension.Loader.load_for_session/2`.
  @spec __action_closures__(GenServer.server()) :: map()
  def __action_closures__(server) do
    %{
      append_entry: fn entry -> GenServer.call(server, {:add_entry, entry, []}) end,
      compact: fn opts -> GenServer.call(server, {:compact, opts}, :infinity) end,
      get_context_usage: fn -> GenServer.call(server, :get_context_usage) end,
      get_compaction_settings: fn -> GenServer.call(server, :get_compaction_settings) end,
      navigate_tree: fn opts -> GenServer.call(server, {:navigate_tree, opts}, :infinity) end,
      get_entries: fn -> GenServer.call(server, :get_entries) end
    }
  end

  # ---- callbacks ----

  @impl true
  def init(opts) do
    extensions = Keyword.fetch!(opts, :extensions)
    store_pid = Keyword.fetch!(opts, :store_pid)
    agent_pid = Keyword.fetch!(opts, :agent_pid)

    OctoPi.Agent.subscribe(agent_pid, self(), :async)

    # Seed Agent's working transcript with the current chain
    # (latest-compaction → leaf). On a fresh session this is empty;
    # on resume it carries the LLM-visible history forward.
    %{messages: seed} = SessionStore.build_session_context(store_pid)
    :ok = OctoPi.Agent.set_messages(agent_pid, seed)

    settings_manager = resolve_settings_manager(opts, store_pid)

    # Flow the configured reserve into Agent so mid-run auto-compact
    # has a threshold to check against. Without this, Agent's
    # `over_threshold?` returns false and mid-run compaction never
    # fires.
    %{reserve_tokens: reserve} = SettingsManager.get_compaction_settings(settings_manager)
    :ok = OctoPi.Agent.set_auto_compact_reserve_tokens(agent_pid, reserve)

    :telemetry.execute(
      [:octo_pi_coder, :loop, :init],
      %{},
      %{agent_pid: agent_pid, reserve_tokens: reserve}
    )

    state = %State{
      extensions: extensions,
      store_pid: store_pid,
      agent_pid: agent_pid,
      model_provider: Keyword.get(opts, :model_provider, fn -> nil end),
      settings_manager: settings_manager
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_session_manager, _from, state),
    do: {:reply, SessionStore.get_session_manager(state.store_pid), state}

  def handle_call(:get_extensions, _from, state), do: {:reply, state.extensions, state}

  def handle_call(:build_session_context, _from, state),
    do: {:reply, SessionStore.build_session_context(state.store_pid), state}

  def handle_call({:add_user_message, %User{} = msg}, _from, state) do
    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_user(msg)
    }

    {state, materialized} = append_to_store(state, entry, [])
    push_entry_to_agent(state.agent_pid, materialized)
    {:reply, {:ok, materialized.id}, state}
  end

  def handle_call({:add_entry, entry, opts}, _from, state) do
    {state, materialized} = append_to_store(state, entry, opts)
    push_entry_to_agent(state.agent_pid, materialized)
    {:reply, {:ok, materialized.id}, state}
  end

  # ---- agent-delegation handles -------------------------------------------

  def handle_call({:agent_subscribe, subscriber, mode}, _from, state) do
    OctoPi.Agent.subscribe(state.agent_pid, subscriber, mode)
    {:reply, :ok, state}
  end

  def handle_call({:agent_prompt, save_text, send_text}, from, state) do
    # Pre-prompt auto-compact: if the current context is over
    # threshold, compact before forwarding the new user message.
    # Mirrors upstream `_handleNewUserMessage` line 1027.
    if pre_prompt_should_compact?(state) do
      # Spawn the compact and defer the prompt forward until it
      # finishes. Continuation tells the compact handler to call
      # forward_prompt(from, save_text, send_text) once it lands.
      {:noreply, start_compact(state, [auto?: true], :pre_prompt, {:forward_prompt, from, save_text, send_text})}
    else
      forward_prompt_now(state, from, save_text, send_text)
    end
  end

  def handle_call(:agent_abort_compact, _from, %State{compact_pending: nil} = state), do: {:reply, :ok, state}

  def handle_call(:agent_abort_compact, _from, %State{compact_pending: %{worker_pid: pid}} = state) do
    # Graceful cancel — the worker's recv loop will pick up :abort,
    # kill its in-flight producer, and reply via {:compact_done, ref,
    # {:cancel, :aborted}}.
    send(pid, :abort)
    {:reply, :ok, state}
  end

  def handle_call(:agent_abort, _from, state) do
    OctoPi.Agent.abort(state.agent_pid)
    {:reply, :ok, state}
  end

  def handle_call({:agent_follow_up, text}, _from, state) do
    {:reply, OctoPi.Agent.follow_up(state.agent_pid, text), state}
  end

  def handle_call({:agent_steer, text}, _from, state) do
    {:reply, OctoPi.Agent.steer(state.agent_pid, text), state}
  end

  def handle_call({:agent_set_model, model}, _from, state) do
    OctoPi.Agent.set_model(state.agent_pid, model)
    {:reply, :ok, state}
  end

  def handle_call({:agent_set_thinking_level, level}, _from, state) do
    OctoPi.Agent.set_thinking_level(state.agent_pid, level)
    {:reply, :ok, state}
  end

  def handle_call({:agent_add_tool, tool}, _from, state) do
    OctoPi.Agent.add_tool(state.agent_pid, tool)
    {:reply, :ok, state}
  end

  def handle_call(:agent_drain_steering, _from, state),
    do: {:reply, OctoPi.Agent.drain_steering(state.agent_pid), state}

  def handle_call(:agent_drain_follow_up, _from, state),
    do: {:reply, OctoPi.Agent.drain_follow_up(state.agent_pid), state}

  # -------------------------------------------------------------------------

  def handle_call({:compact, _opts}, _from, %State{compact_pending: %{}} = state) do
    {:reply, {:error, :busy}, state}
  end

  def handle_call({:compact, opts}, from, state) do
    # Manual compact: spawn the LLM work in a Task so the GenServer
    # stays responsive. `:abort_compact` can kill the task; the
    # original caller's reply is deferred until the task finishes
    # or is killed.
    OctoPi.Agent.abort(state.agent_pid)
    {:noreply, start_compact(state, opts, :manual, {:reply, from})}
  end

  def handle_call({:fork, opts}, _from, state) do
    started_mono = System.monotonic_time()
    leaf_id = SessionStore.get_leaf_entry_id(state.store_pid)
    result = do_fork(state, opts)

    :telemetry.execute(
      [:octo_pi_coder, :fork, :stop],
      %{duration: System.monotonic_time() - started_mono},
      %{old_leaf_id: leaf_id, target_dir: Keyword.get(opts, :target_dir), result: fork_result_kind(result)}
    )

    {:reply, result, state}
  end

  def handle_call({:navigate_tree, opts}, _from, state) do
    started_mono = System.monotonic_time()
    target_id = Keyword.get(opts, :target_id)
    old_leaf_id = SessionStore.get_leaf_entry_id(state.store_pid)

    :telemetry.execute(
      [:octo_pi_coder, :navigate, :start],
      %{},
      %{target_id: target_id, old_leaf_id: old_leaf_id}
    )

    nav_result = do_navigate_tree(state, opts)

    case nav_result do
      {:ok, summary, ^old_leaf_id, new_state} ->
        # Rewrite Agent's transcript to the new chain. Mirrors
        # upstream `AgentSession.navigateTree` line 2836:
        # `this.agent.state.messages = sessionContext.messages`.
        %{messages: msgs} = SessionStore.build_session_context(new_state.store_pid)
        :ok = OctoPi.Agent.set_messages(new_state.agent_pid, msgs)

        ctx = build_ctx(new_state)

        tree_event =
          Event.new(:session_tree, %{
            new_leaf_id: SessionStore.get_leaf_entry_id(new_state.store_pid),
            old_leaf_id: old_leaf_id
          })

        Dispatcher.emit(state.extensions, tree_event, ctx)

        :telemetry.execute(
          [:octo_pi_coder, :navigate, :stop],
          %{duration: System.monotonic_time() - started_mono},
          %{
            old_leaf_id: old_leaf_id,
            new_leaf_id: SessionStore.get_leaf_entry_id(new_state.store_pid),
            summarized?: not is_nil(summary),
            result: :ok
          }
        )

        {:reply, {:ok, summary}, new_state}

      other ->
        :telemetry.execute(
          [:octo_pi_coder, :navigate, :stop],
          %{duration: System.monotonic_time() - started_mono},
          %{old_leaf_id: old_leaf_id, summarized?: false, result: navigate_result_kind(other)}
        )

        {:reply, other, state}
    end
  end

  def handle_call(:get_context_usage, _from, state), do: {:reply, do_get_context_usage(state), state}

  def handle_call(:get_session_stats, _from, state), do: {:reply, do_get_session_stats(state), state}

  def handle_call(:get_compaction_settings, _from, state),
    do: {:reply, SettingsManager.get_compaction_settings(state.settings_manager), state}

  def handle_call(:get_entries, _from, state), do: {:reply, SessionStore.get_entries(state.store_pid), state}

  # ---- compact (manual + pre-prompt) --------------------------------------

  # Pre-prompt threshold check used by :agent_prompt to decide whether
  # to compact before forwarding the prompt. Emits the
  # :pre_prompt_check telemetry event and returns true/false.
  defp pre_prompt_should_compact?(%State{} = state) do
    settings = SettingsManager.get_compaction_settings(state.settings_manager)
    usage = do_get_context_usage(state)
    triggered? = check_should_compact(settings, usage)

    :telemetry.execute(
      [:octo_pi_coder, :pre_prompt_check],
      %{},
      %{
        triggered?: triggered?,
        tokens: usage && usage.tokens,
        context_window: usage && usage.context_window,
        enabled?: settings.enabled
      }
    )

    triggered?
  end

  defp check_should_compact(settings, usage) do
    with true <- settings.enabled,
         %{tokens: t, context_window: cw} when is_integer(t) and is_integer(cw) <- usage do
      Tokens.should_compact?(t, cw, settings)
    else
      _ -> false
    end
  end

  # Drive a compaction. The synchronous prep + extension hooks run
  # inline (in the GenServer); only the LLM call is spawned via
  # `Compaction.async/5`, which owns the worker process and its
  # producer. Short-circuit cases (nothing-to-compact, no-model,
  # extension cancel/override) finish without spawning at all.
  defp start_compact(%State{} = state, opts, source, continuation) do
    started_mono = System.monotonic_time()
    tokens_before = compact_tokens_before(state)

    :telemetry.execute(
      [:octo_pi_coder, :compact, :start],
      %{},
      %{source: source, tokens_before: tokens_before}
    )

    Subscribers.dispatch(
      state.agent_pid,
      %OctoPi.Coder.Event.CompactionStart{reason: source}
    )

    case prep_for_compact(state, opts) do
      {:short_circuit, result} ->
        # No LLM needed; skip the spawn and finalize inline.
        pending = %{
          source: source,
          continuation: continuation,
          started_mono: started_mono,
          tokens_before: tokens_before
        }

        finish_compact(%{state | compact_pending: pending}, result, false)

      {:run_llm, prep, model, llm_opts} ->
        worker_ref = make_ref()
        {:ok, worker_pid} = Compaction.async(self(), worker_ref, prep, model, llm_opts)
        monitor_ref = Process.monitor(worker_pid)

        pending = %{
          worker_pid: worker_pid,
          worker_ref: worker_ref,
          monitor_ref: monitor_ref,
          source: source,
          continuation: continuation,
          started_mono: started_mono,
          tokens_before: tokens_before
        }

        %{state | compact_pending: pending}
    end
  end

  defp prep_for_compact(%State{} = state, opts) do
    settings = SettingsManager.get_compaction_settings(state.settings_manager)
    path = SessionStore.path(state.store_pid, :leaf, to: :latest_compaction)

    case Preparation.prepare(path, settings) do
      nil ->
        {:short_circuit, {:error, :nothing_to_compact}}

      %Preparation{} = prep ->
        ctx = build_ctx(state)

        event =
          Event.new(:session_before_compact, %{
            preparation: prep,
            custom_instructions: Keyword.get(opts, :custom_instructions)
          })

        decide_compact(state, prep, opts, Dispatcher.halt_on_result(state.extensions, event, ctx))
    end
  end

  defp decide_compact(_state, _prep, _opts, {:cancel, reason}), do: {:short_circuit, {:cancel, reason}}

  defp decide_compact(_state, _prep, _opts, {:override, %Result{} = result}),
    do: {:short_circuit, {:ok, %{result: result, from_extension?: true}}}

  defp decide_compact(state, prep, opts, :ok) do
    case state.model_provider.() do
      nil -> {:short_circuit, {:error, :no_model}}
      model -> {:run_llm, prep, model, opts}
    end
  end

  # Run after the compact task settles (either via :compact_complete
  # or :DOWN). Persists the result if successful, fires telemetry +
  # CompactionEnd, runs the continuation, and clears compact_pending.
  defp finish_compact(%State{compact_pending: nil} = state, _result, _aborted?), do: state

  defp finish_compact(%State{compact_pending: pending} = state, result, aborted?) do
    if monitor = Map.get(pending, :monitor_ref) do
      Process.demonitor(monitor, [:flush])
    end

    {final_result, state} =
      case result do
        {:ok, %{result: r, from_extension?: from_ext?}} = ok ->
          new_state = finalize_compact(state, r, from_ext?)
          {ok, new_state}

        other ->
          {other, state}
      end

    :telemetry.execute(
      [:octo_pi_coder, :compact, :stop],
      %{duration: System.monotonic_time() - pending.started_mono},
      %{
        source: pending.source,
        result: compact_result_kind(final_result),
        tokens_before: pending.tokens_before,
        tokens_after: compact_tokens_before(state),
        from_extension?: from_extension?(final_result),
        aborted?: aborted?
      }
    )

    Subscribers.dispatch(
      state.agent_pid,
      %OctoPi.Coder.Event.CompactionEnd{
        result: final_result,
        reason: pending.source,
        aborted?: aborted?
      }
    )

    state = %{state | compact_pending: nil}
    apply_continuation(state, pending.continuation, final_result)
  end

  # Run the deferred continuation now that the compact has settled.
  defp apply_continuation(state, {:reply, from}, result) do
    GenServer.reply(from, result)
    state
  end

  defp apply_continuation(state, {:forward_prompt, from, save_text, send_text}, _result) do
    {:reply, reply, state} = forward_prompt_now(state, from, save_text, send_text)
    GenServer.reply(from, reply)
    state
  end

  defp apply_continuation(state, {:agent_response, ref}, {:ok, %{from_extension?: from_ext?}} = ok) do
    OctoPi.Agent.compaction_response(state.agent_pid, ref, agent_compaction_payload(ok, from_ext?))
    state
  end

  defp apply_continuation(state, {:agent_response, ref}, other) do
    OctoPi.Agent.compaction_response(state.agent_pid, ref, other)
    state
  end

  defp compact_tokens_before(state) do
    case do_get_context_usage(state) do
      %{tokens: t} when is_integer(t) -> t
      _ -> nil
    end
  end

  defp compact_result_kind({:ok, _}), do: :ok
  defp compact_result_kind({:cancel, _}), do: :cancel
  defp compact_result_kind({:error, reason}), do: {:error, reason}

  defp from_extension?({:ok, %{from_extension?: v}}), do: v
  defp from_extension?(_), do: false

  defp fork_result_kind({:ok, _}), do: :ok
  defp fork_result_kind({:cancel, _}), do: :cancel
  defp fork_result_kind({:error, reason}), do: {:error, reason}

  defp navigate_result_kind({:cancel, _}), do: :cancel
  defp navigate_result_kind({:error, reason}), do: {:error, reason}
  defp navigate_result_kind(_), do: :unknown

  # The body of `:agent_prompt` after pre-prompt-compact has settled.
  # Returns a `{:reply, reply, state}` tuple — used both as the
  # immediate handle_call return when no compact was needed and via
  # apply_continuation/3 after a deferred compact lands.
  defp forward_prompt_now(state, _from, save_text, send_text) do
    user_msg = %User{
      content: [%OctoPi.AI.Content.Text{text: save_text}],
      timestamp: :os.system_time(:millisecond)
    }

    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_user(user_msg)
    }

    {state, _materialized} = append_to_store(state, entry, [])
    {:reply, OctoPi.Agent.prompt(state.agent_pid, send_text), state}
  end

  # Persist the Compaction entry, refresh the cached path, rewrite
  # Agent's transcript, and emit the `:session_compact` extension
  # event. Used by both the manual path (handle_call({:compact, _}))
  # and the mid-run auto path (handle_info({:CompactionRequested,_})).
  defp finalize_compact(%State{} = state, %Result{} = result, from_ext?) do
    entry = %Entry.Compaction{
      id: nil,
      timestamp: nil,
      summary: result.summary,
      first_kept_entry_id: result.first_kept_entry_id,
      tokens_before: result.tokens_before,
      from_hook: if(from_ext?, do: true),
      details: result.details
    }

    {state, _materialized} = append_to_store(state, entry, [])

    %{messages: msgs} = SessionStore.build_session_context(state.store_pid)
    :ok = OctoPi.Agent.set_messages(state.agent_pid, msgs)

    sm = SessionStore.get_session_manager(state.store_pid)
    ctx = Context.bind_session_manager(%Context{cwd: sm.cwd}, fn -> sm end)
    stored = sm.file_entries |> Enum.reverse() |> Enum.find(&match?(%Entry.Compaction{}, &1))

    Dispatcher.emit(
      state.extensions,
      Event.new(:session_compact, %{compaction_entry: stored, from_extension?: from_ext?}),
      ctx
    )

    state
  end

  # ---- fork ----------------------------------------------------------------

  defp do_fork(%State{} = state, opts) do
    ctx = build_ctx(state)
    leaf_id = SessionStore.get_leaf_entry_id(state.store_pid)
    event = Event.new(:session_before_fork, %{entry_id: leaf_id})

    case Dispatcher.halt_on_result(state.extensions, event, ctx) do
      {:cancel, reason} ->
        {:cancel, reason}

      :ok ->
        SessionStore.fork(
          state.store_pid,
          Keyword.fetch!(opts, :target_cwd),
          Keyword.fetch!(opts, :target_dir),
          Keyword.take(opts, [:id, :timestamp])
        )
    end
  end

  # ---- navigate_tree -------------------------------------------------------

  defp do_navigate_tree(%State{} = state, opts) do
    target_id = Keyword.fetch!(opts, :target_id)
    old_leaf_id = SessionStore.get_leaf_entry_id(state.store_pid)

    if target_id == old_leaf_id do
      {:ok, nil, old_leaf_id, state}
    else
      case SessionStore.get_entry(state.store_pid, target_id) do
        nil -> {:error, :not_found}
        target_entry -> navigate_to_entry(state, target_entry, target_id, old_leaf_id, opts)
      end
    end
  end

  defp navigate_to_entry(state, target_entry, target_id, old_leaf_id, opts) do
    {entries_to_summarize, common_ancestor_id} =
      SessionStore.collect_entries_for_branch_summary(state.store_pid, old_leaf_id, target_id)

    user_wants_summary = Keyword.get(opts, :user_wants_summary, :no)

    prep = %TreePreparation{
      target_id: target_id,
      old_leaf_id: old_leaf_id,
      common_ancestor_id: common_ancestor_id,
      entries_to_summarize: entries_to_summarize,
      user_wants_summary: user_wants_summary
    }

    ctx = build_ctx(state)
    event = Event.new(:session_before_tree, %{preparation: prep})

    case Dispatcher.halt_on_result(state.extensions, event, ctx) do
      {:cancel, reason} ->
        {:cancel, reason}

      {:override, %BranchSummaryResult{} = ext_result} when user_wants_summary != :no ->
        new_state =
          branch_with_or_without_summary(state, target_entry, target_id, old_leaf_id, ext_result, true)

        {:ok, ext_result, old_leaf_id, new_state}

      _ ->
        run_default_navigate(
          state,
          target_entry,
          target_id,
          old_leaf_id,
          entries_to_summarize,
          user_wants_summary,
          opts
        )
    end
  end

  defp run_default_navigate(state, target_entry, target_id, old_leaf_id, entries, user_wants_summary, opts) do
    if user_wants_summary == :no or entries == [] do
      {:ok, nil, old_leaf_id, set_new_leaf(state, target_entry, target_id)}
    else
      run_navigate_with_summary(state, target_entry, target_id, old_leaf_id, entries, user_wants_summary, opts)
    end
  end

  defp run_navigate_with_summary(state, target_entry, target_id, old_leaf_id, entries, user_wants_summary, opts) do
    case Keyword.get(opts, :model) do
      nil ->
        {:error, :no_model}

      model ->
        generate_opts = build_summary_opts(model, user_wants_summary, opts)
        run_branch_summarization(state, target_entry, target_id, old_leaf_id, entries, generate_opts)
    end
  end

  defp run_branch_summarization(state, target_entry, target_id, old_leaf_id, entries, generate_opts) do
    case BranchSummarization.generate(entries, generate_opts) do
      {:ok, %BranchSummaryResult{} = result} ->
        new_state =
          branch_with_or_without_summary(state, target_entry, target_id, old_leaf_id, result, false)

        {:ok, result, old_leaf_id, new_state}

      :aborted ->
        {:cancel, :aborted}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_summary_opts(model, user_wants_summary, opts) do
    base = [
      model: model,
      api_key: Keyword.get(opts, :api_key),
      headers: Keyword.get(opts, :headers)
    ]

    base =
      case Keyword.get(opts, :producer) do
        nil -> base
        producer -> [{:producer, producer} | base]
      end

    case user_wants_summary do
      :yes -> base
      {:yes, instructions} -> [{:custom_instructions, instructions} | base]
    end
  end

  defp branch_with_or_without_summary(state, target_entry, target_id, old_leaf_id, summary_result, from_hook) do
    new_leaf_id = compute_new_leaf_id(target_entry, target_id)
    :ok = SessionStore.set_leaf(state.store_pid, new_leaf_id)

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

    {:ok, _materialized} = SessionStore.append_entry(state.store_pid, entry, [])
    state
  end

  defp set_new_leaf(state, target_entry, target_id) do
    :ok = SessionStore.set_leaf(state.store_pid, compute_new_leaf_id(target_entry, target_id))
    state
  end

  defp compute_new_leaf_id(%Entry.Message{message: %{"role" => "user"}, parent_id: pid}, _target_id), do: pid

  defp compute_new_leaf_id(_entry, target_id), do: target_id

  # ---- agent event handling ----

  @impl true
  def handle_info({:octo_pi_agent_event, %OctoPi.Agent.Event.MessageEnd{message: msg}}, state) do
    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_assistant(msg)
    }

    {state, _materialized} = append_to_store(state, entry, [])
    {:noreply, state}
  end

  def handle_info(
        {:octo_pi_agent_event,
         %OctoPi.Agent.Event.ToolExecutionEnd{tool_call_id: call_id, tool_name: name, result: result}},
        state
      ) do
    tool_result = %OctoPi.AI.Message.ToolResult{
      tool_call_id: call_id,
      tool_name: name,
      content: result.content,
      is_error?: result.is_error?,
      details: result.details,
      timestamp: :os.system_time(:millisecond)
    }

    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_tool_result(tool_result)
    }

    {state, _materialized} = append_to_store(state, entry, [])
    {:noreply, state}
  end

  def handle_info({:octo_pi_agent_event, %OctoPi.Agent.Event.CompactionRequested{ref: ref, opts: opts}}, state) do
    # Mid-run auto-compact: Agent paused between turns and asked the
    # host to compact. Spawn the work; on completion (or kill), the
    # `{:agent_response, ref}` continuation threads the result back
    # to Agent's FSM via compaction_response/3.
    {:noreply, start_compact(state, opts, :mid_run, {:agent_response, ref})}
  end

  def handle_info({:compact_done, worker_ref, result}, %State{compact_pending: pending} = state)
      when not is_nil(pending) and pending.worker_ref == worker_ref do
    # `Compaction.async` produces results in the `{:ok, %Result{}} |
    # {:error, _} | {:cancel, :aborted}` shape; wrap into the
    # `compact_result()` shape Coder.Loop's continuations expect
    # (with `from_extension?` always false on this LLM path).
    {wrapped, aborted?} =
      case result do
        {:ok, %Result{} = r} -> {{:ok, %{result: r, from_extension?: false}}, false}
        {:cancel, :aborted} = c -> {c, true}
        other -> {other, false}
      end

    {:noreply, finish_compact(state, wrapped, aborted?)}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, :normal}, %State{compact_pending: pending} = state)
      when is_map(pending) and is_map_key(pending, :monitor_ref) and
             :erlang.map_get(:monitor_ref, pending) == monitor_ref do
    # Worker exited cleanly — `:compact_done` is either being
    # processed or sitting in the mailbox. Drop the DOWN.
    {:noreply, state}
  end

  def handle_info({:DOWN, monitor_ref, :process, _pid, reason}, %State{compact_pending: pending} = state)
      when is_map(pending) and is_map_key(pending, :monitor_ref) and
             :erlang.map_get(:monitor_ref, pending) == monitor_ref do
    # Worker crashed unexpectedly. (Brutal kill via Process.exit/2
    # is no longer used — :abort_compact sends a graceful :abort
    # message — so any non-:normal DOWN is a true crash.)
    {:noreply, finish_compact(state, {:error, {:worker_crashed, reason}}, false)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Translate the Coder-shaped compact_result into the payload Agent's
  # FSM expects on compaction_response/3 (a flatter map without the
  # Result struct nesting).
  defp agent_compaction_payload({:ok, %{result: %Result{} = r}}, from_ext?) do
    {:ok,
     %{
       summary: r.summary,
       first_kept_entry_id: r.first_kept_entry_id,
       tokens_before: r.tokens_before,
       details: r.details,
       from_extension?: from_ext?
     }}
  end

  # ---- get_context_usage / get_session_stats --------------------------------
  # Mirrors upstream AgentSession.getContextUsage / getSessionStats
  # (agent-session.ts:2932-2973, 2887-2932).

  defp do_get_context_usage(%State{model_provider: mp, store_pid: store_pid}) do
    case mp.() do
      %{context_window: cw} when is_integer(cw) and cw > 0 ->
        path = SessionStore.path(store_pid, :leaf, to: :root)

        if context_tokens_known?(path) do
          messages = SessionStore.build_session_context(store_pid).messages
          estimate = Tokens.estimate_context_tokens(messages)
          percent = estimate.tokens / cw * 100
          %{tokens: estimate.tokens, context_window: cw, percent: percent}
        else
          %{tokens: nil, context_window: cw, percent: nil}
        end

      _ ->
        nil
    end
  end

  defp do_get_session_stats(%State{} = state) do
    messages = SessionStore.build_session_context(state.store_pid).messages

    {input, output, cache_read, cache_write} =
      Enum.reduce(messages, {0, 0, 0, 0}, fn
        %{"role" => "assistant", "usage" => u}, {i, o, cr, cw} when is_map(u) ->
          {i + map_int(u, "input"), o + map_int(u, "output"), cr + map_int(u, "cacheRead"),
           cw + map_int(u, "cacheWrite")}

        _, acc ->
          acc
      end)

    %{
      tokens: %{
        input: input,
        output: output,
        cache_read: cache_read,
        cache_write: cache_write,
        total: input + output + cache_read + cache_write
      },
      context_usage: do_get_context_usage(state)
    }
  end

  # Returns true iff context tokens are currently knowable — either no
  # compaction exists, or a valid (non-aborted, non-error) assistant
  # response exists after the latest compaction boundary.
  defp context_tokens_known?(branch) do
    case find_latest_compaction_index(branch) do
      nil -> true
      comp_idx -> post_compaction_valid_assistant?(branch, comp_idx)
    end
  end

  defp find_latest_compaction_index(branch) do
    branch
    |> Enum.with_index()
    |> Enum.reduce(nil, fn
      {%Entry.Compaction{}, idx}, _ -> idx
      _, acc -> acc
    end)
  end

  # Walk newest → oldest after the compaction; stop at the first
  # non-aborted/error assistant and check its token count.
  defp post_compaction_valid_assistant?(branch, comp_idx) do
    branch
    |> Enum.drop(comp_idx + 1)
    |> Enum.reverse()
    |> Enum.reduce_while(false, fn
      %Entry.Message{message: %{"role" => "assistant", "stopReason" => r}}, acc
      when r in ["aborted", "error"] ->
        {:cont, acc}

      %Entry.Message{message: %{"role" => "assistant"} = msg}, _acc ->
        u = msg["usage"] || %{}
        total = map_int(u, "totalTokens")

        tokens =
          if total > 0,
            do: total,
            else: map_int(u, "input") + map_int(u, "output") + map_int(u, "cacheRead") + map_int(u, "cacheWrite")

        {:halt, tokens > 0}

      _, acc ->
        {:cont, acc}
    end)
  end

  defp map_int(map, key) when is_map(map) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # -- helpers --

  defp append_to_store(state, entry, opts) do
    {:ok, materialized} = SessionStore.append_entry(state.store_pid, entry, opts)
    {state, materialized}
  end

  # Mirror Coder-originated entries into Agent's working transcript.
  # Skips entries the Agent already pushed itself (streamed assistant /
  # tool_result) and the Compaction chain-head (rewritten wholesale by
  # the compactor, not appended onto the tail).
  defp push_entry_to_agent(_agent_pid, %Entry.Message{message: %{"role" => role}})
       when role in ["assistant", "toolResult"], do: :ok

  defp push_entry_to_agent(_agent_pid, %Entry.Compaction{}), do: :ok

  defp push_entry_to_agent(agent_pid, entry) do
    for msg <- SessionManager.entry_to_messages(entry) do
      :ok = OctoPi.Agent.push_message(agent_pid, msg)
    end

    :ok
  end

  defp build_ctx(state) do
    Context.bind_session_manager(
      %Context{cwd: SessionStore.get_cwd(state.store_pid)},
      fn -> SessionStore.get_session_manager(state.store_pid) end
    )
  end

  defp resolve_settings_manager(opts, store_pid) do
    case Keyword.get(opts, :settings_manager) do
      nil ->
        # Production default: load global + project settings from disk
        # (~/.pi/agent/settings.json + <cwd>/.pi/settings.json). Tests
        # that don't want disk I/O pass an explicit :settings_manager.
        {:ok, pid} = SettingsManager.create(SessionStore.get_cwd(store_pid))
        pid

      pid ->
        pid
    end
  end
end
