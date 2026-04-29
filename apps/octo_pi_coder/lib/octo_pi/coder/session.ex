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

  All public operations are surfaced through `OctoPi.Coder`. The bridge
  into the extension API (a closure map per `Extension.API.bind_core/2`)
  is built inside `Extension.Loader.load_for_session/2` and is not
  exposed here.
  """

  use GenServer, restart: :temporary

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
  alias OctoPi.Coder.Session
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.Session.MessageWriter
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SettingsManager

  @typedoc "Optional providers default to closures returning sensible nils / defaults."
  @type model_provider :: (-> term() | nil)

  @type state :: %__MODULE__.State{
          extensions: [Extension.t()],
          session_manager: SessionManager.t(),
          store_pid: pid(),
          agent_pid: pid() | nil,
          model_provider: model_provider(),
          settings_manager: pid()
        }

  defmodule State do
    @moduledoc false

    @enforce_keys [:extensions, :session_manager, :store_pid, :model_provider, :settings_manager]
    defstruct [
      :extensions,
      :session_manager,
      :store_pid,
      :agent_pid,
      :model_provider,
      :settings_manager
    ]
  end

  @type start_opts :: [
          extensions: [Extension.t()],
          session_manager: SessionManager.t(),
          store_pid: pid(),
          agent_pid: pid() | nil,
          model_provider: Session.model_provider(),
          settings_manager: pid(),
          name: GenServer.name()
        ]

  @doc """
  Start a session under `OctoPi.Coder.Session.Supervisor` (DynamicSupervisor).
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
    _ = Keyword.fetch!(opts, :session_manager)
    _ = Keyword.fetch!(opts, :store_pid)

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
          {:ok, SessionManager.t()}
          | {:cancel, term()}
          | {:error, :enoent | :empty | :missing_header | :no_session_file}

  @type navigate_tree_result ::
          {:ok, BranchSummaryResult.t() | nil}
          | {:cancel, term()}
          | {:error, :not_found | :no_model | term()}

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
      settings_manager: resolve_settings_manager(opts)
    }

    {:ok, state}
  end

  @impl true
  def handle_call(:get_session_manager, _from, state), do: {:reply, state.session_manager, state}

  def handle_call(:get_extensions, _from, state), do: {:reply, state.extensions, state}

  def handle_call(:build_session_context, _from, state),
    do: {:reply, SessionManager.build_session_context(state.session_manager), state}

  def handle_call({:add_user_message, %User{} = msg}, _from, state) do
    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_user(msg)
    }

    forward_opts = [store: state.store_pid]
    {sm, id} = SessionManager.add_entry(state.session_manager, entry, forward_opts)
    {:reply, {:ok, id}, %{state | session_manager: sm}}
  end

  def handle_call({:add_entry, entry, opts}, _from, state) do
    forward_opts = Keyword.put(opts, :store, state.store_pid)
    {sm, id} = SessionManager.add_entry(state.session_manager, entry, forward_opts)
    {:reply, {:ok, id}, %{state | session_manager: sm}}
  end

  def handle_call({:set_agent_pid, agent_pid}, _from, state) do
    OctoPi.Agent.subscribe(agent_pid, self(), :async)
    {:reply, :ok, %{state | agent_pid: agent_pid}}
  end

  # ---- agent-delegation handles -------------------------------------------

  def handle_call({:agent_subscribe, subscriber, mode}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.subscribe(state.agent_pid, subscriber, mode)
    {:reply, :ok, state}
  end

  def handle_call({:agent_prompt, save_text, send_text}, _from, state) do
    user_msg = %User{
      content: [%OctoPi.AI.Content.Text{text: save_text}],
      timestamp: :os.system_time(:millisecond)
    }

    entry = %Entry.Message{
      id: nil,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      message: MessageWriter.from_user(user_msg)
    }

    {sm, _id} = SessionManager.add_entry(state.session_manager, entry, store: state.store_pid)
    result = if state.agent_pid, do: OctoPi.Agent.prompt(state.agent_pid, send_text), else: {:error, :no_agent}
    {:reply, result, %{state | session_manager: sm}}
  end

  def handle_call(:agent_abort, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.abort(state.agent_pid)
    {:reply, :ok, state}
  end

  def handle_call({:agent_follow_up, text}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.follow_up(state.agent_pid, text)
    {:reply, :ok, state}
  end

  def handle_call({:agent_steer, text}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.steer(state.agent_pid, text)
    {:reply, :ok, state}
  end

  def handle_call({:agent_set_model, model}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.set_model(state.agent_pid, model)
    {:reply, :ok, state}
  end

  def handle_call({:agent_set_thinking_level, level}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.set_thinking_level(state.agent_pid, level)
    {:reply, :ok, state}
  end

  def handle_call({:agent_add_tool, tool}, _from, state) do
    if state.agent_pid, do: OctoPi.Agent.add_tool(state.agent_pid, tool)
    {:reply, :ok, state}
  end

  def handle_call(:agent_drain_steering, _from, state) do
    result = if state.agent_pid, do: OctoPi.Agent.drain_steering(state.agent_pid), else: []
    {:reply, result, state}
  end

  def handle_call(:agent_drain_follow_up, _from, state) do
    result = if state.agent_pid, do: OctoPi.Agent.drain_follow_up(state.agent_pid), else: []
    {:reply, result, state}
  end

  # -------------------------------------------------------------------------

  def handle_call({:compact, _opts}, from, %{agent_pid: agent_pid} = state) when is_pid(agent_pid) do
    # Route through the agent FSM: Agent emits CompactionRequested, our
    # handle_info handler runs the LLM, calls finish_compaction (which
    # writes the entry + compaction_response). Reply immediately so we
    # don't deadlock waiting for an event that flows back through us.
    GenServer.reply(from, :ok)
    OctoPi.Agent.compact(agent_pid)
    {:noreply, state}
  end

  def handle_call({:compact, opts}, _from, state) do
    case do_compact(state, opts) do
      {:ok, %{result: result, from_extension?: from_ext?}} ->
        session_pid = self()
        extensions = state.extensions
        spawn(fn -> persist_compaction(session_pid, result, from_ext?, extensions) end)
        {:reply, {:ok, %{result: result, from_extension?: from_ext?}}, state}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call({:fork, opts}, _from, state) do
    {:reply, do_fork(state, opts), state}
  end

  def handle_call({:navigate_tree, opts}, _from, state) do
    case do_navigate_tree(state, opts) do
      {:ok, summary, old_leaf_id, new_sm} ->
        ctx =
          Context.bind_session_manager(%Context{cwd: new_sm.cwd}, fn -> new_sm end)

        tree_event =
          Event.new(:session_tree, %{
            new_leaf_id: new_sm.leaf_id,
            old_leaf_id: old_leaf_id
          })

        Dispatcher.emit(state.extensions, tree_event, ctx)
        {:reply, {:ok, summary}, %{state | session_manager: new_sm}}

      other ->
        {:reply, other, state}
    end
  end

  def handle_call(:get_context_usage, _from, state), do: {:reply, do_get_context_usage(state), state}

  def handle_call(:get_session_stats, _from, state), do: {:reply, do_get_session_stats(state), state}

  def handle_call(:get_compaction_settings, _from, state),
    do: {:reply, SettingsManager.get_compaction_settings(state.settings_manager), state}

  def handle_call(:get_entries, _from, state), do: {:reply, SessionManager.get_entries(state.session_manager), state}

  defp do_compact(%State{} = state, opts) do
    path_entries = SessionManager.get_branch(state.session_manager)
    settings = SettingsManager.get_compaction_settings(state.settings_manager)

    case Preparation.prepare(path_entries, settings) do
      nil ->
        {:error, :nothing_to_compact}

      %Preparation{} = prep ->
        dispatch_compact(state, prep, opts)
    end
  end

  defp dispatch_compact(%State{} = state, prep, opts) do
    ctx =
      Context.bind_session_manager(%Context{cwd: state.session_manager.cwd}, fn -> state.session_manager end)

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
        Context.bind_session_manager(%Context{cwd: state.session_manager.cwd}, fn -> state.session_manager end)

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
        nil -> {:error, :not_found}
        target_entry -> navigate_to_entry(state, target_entry, target_id, old_leaf_id, opts)
      end
    end
  end

  defp navigate_to_entry(state, target_entry, target_id, old_leaf_id, opts) do
    {entries_to_summarize, common_ancestor_id} =
      SessionManager.collect_entries_for_branch_summary(state.session_manager, old_leaf_id, target_id)

    user_wants_summary = Keyword.get(opts, :user_wants_summary, :no)

    prep = %TreePreparation{
      target_id: target_id,
      old_leaf_id: old_leaf_id,
      common_ancestor_id: common_ancestor_id,
      entries_to_summarize: entries_to_summarize,
      user_wants_summary: user_wants_summary
    }

    ctx = Context.bind_session_manager(%Context{cwd: state.session_manager.cwd}, fn -> state.session_manager end)
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
      {:ok, nil, old_leaf_id, set_new_leaf(state.session_manager, target_entry, target_id)}
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

    {sm, _id} = SessionManager.add_entry(state.session_manager, entry, store: state.store_pid)
    {:noreply, %{state | session_manager: sm}}
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

    {sm, _id} = SessionManager.add_entry(state.session_manager, entry, store: state.store_pid)
    {:noreply, %{state | session_manager: sm}}
  end

  def handle_info(
        {:octo_pi_agent_event, %OctoPi.Agent.Event.CompactionRequested{ref: ref, opts: opts}},
        %State{agent_pid: agent_pid} = state
      ) do
    path_entries = SessionManager.get_branch(state.session_manager)
    settings = SettingsManager.get_compaction_settings(state.settings_manager)

    case Preparation.prepare(path_entries, settings) do
      nil ->
        OctoPi.Agent.compaction_response(agent_pid, ref, {:error, :nothing_to_compact})
        {:noreply, state}

      %Preparation{} = prep ->
        ctx =
          Context.bind_session_manager(%Context{cwd: state.session_manager.cwd}, fn -> state.session_manager end)

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
            spawn_finish_compaction(self(), agent_pid, ref, result, true, state.extensions)
            {:noreply, state}

          :ok ->
            dispatch_compaction(state, agent_pid, ref, prep, opts)
        end
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp dispatch_compaction(state, agent_pid, ref, prep, opts) do
    case state.model_provider.() do
      nil ->
        OctoPi.Agent.compaction_response(agent_pid, ref, {:error, :no_model})

      model ->
        spawn_compact_and_finish(self(), agent_pid, ref, prep, model, opts, state.extensions)
    end

    {:noreply, state}
  end

  defp spawn_finish_compaction(session_pid, agent_pid, ref, result, override?, extensions) do
    spawn(fn -> finish_compaction(session_pid, agent_pid, ref, result, override?, extensions) end)
  end

  defp spawn_compact_and_finish(session_pid, agent_pid, ref, prep, model, opts, extensions) do
    spawn(fn ->
      case Compaction.compact(prep, model, opts) do
        {:ok, %Result{} = result} -> finish_compaction(session_pid, agent_pid, ref, result, false, extensions)
        {:error, reason} -> OctoPi.Agent.compaction_response(agent_pid, ref, {:error, reason})
      end
    end)
  end

  # ---- get_context_usage / get_session_stats --------------------------------
  # Mirrors upstream AgentSession.getContextUsage / getSessionStats
  # (agent-session.ts:2932-2973, 2887-2932).

  defp do_get_context_usage(%State{model_provider: mp, session_manager: sm}) do
    case mp.() do
      %{context_window: cw} when is_integer(cw) and cw > 0 ->
        branch = SessionManager.get_branch(sm)

        if context_tokens_known?(branch) do
          messages = SessionManager.build_session_context(sm).messages
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

  defp do_get_session_stats(%State{session_manager: sm} = state) do
    messages = SessionManager.build_session_context(sm).messages

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

  defp finish_compaction(session_pid, agent_pid, ref, %Result{} = result, from_ext?, extensions) do
    persist_compaction(session_pid, result, from_ext?, extensions)

    OctoPi.Agent.compaction_response(
      agent_pid,
      ref,
      {:ok,
       %{
         summary: result.summary,
         first_kept_entry_id: result.first_kept_entry_id,
         tokens_before: result.tokens_before,
         details: result.details,
         from_extension?: from_ext?
       }}
    )
  end

  defp persist_compaction(session_pid, %Result{} = result, from_ext?, extensions) do
    entry = %Entry.Compaction{
      id: nil,
      timestamp: nil,
      summary: result.summary,
      first_kept_entry_id: result.first_kept_entry_id,
      tokens_before: result.tokens_before,
      from_hook: if(from_ext?, do: true),
      details: result.details
    }

    {:ok, id} = GenServer.call(session_pid, {:add_entry, entry, []})
    sm = GenServer.call(session_pid, :get_session_manager)
    stored = Map.fetch!(sm.by_id, id)
    ctx = Context.bind_session_manager(%Context{cwd: sm.cwd}, fn -> sm end)

    Dispatcher.emit(
      extensions,
      Event.new(:session_compact, %{compaction_entry: stored, from_extension?: from_ext?}),
      ctx
    )
  end

  defp resolve_settings_manager(opts) do
    case Keyword.get(opts, :settings_manager) do
      nil ->
        {:ok, pid} = SettingsManager.in_memory()
        pid

      pid ->
        pid
    end
  end
end
