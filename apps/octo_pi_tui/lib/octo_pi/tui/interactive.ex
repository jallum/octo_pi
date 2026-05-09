defmodule OctoPi.TUI.Interactive do
  @moduledoc """
  Main loop for `mix pi` interactive mode.

  Composes the Phase 4 pieces end-to-end: `Terminal` owns the tty,
  assembles cooked stdin sequences, and parses them into key events;
  the `Input` component accumulates the prompt, and the `Renderer`
  paints the transcript + input to the screen. Agent events from
  `OctoPi.Agent.Loop` drive the transcript updates.

  The state machine is a pure function: `handle_event/2` takes a
  state and an event (key, agent event, or resize) and returns a
  new state. Tests drive it directly without any tty.
  `run/1` starts this GenServer, blocks until it exits, and returns
  `:ok`.
  """

  @behaviour OctoPi.Coder.UIHost

  use GenServer

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Event.MessageEnd
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Model
  alias OctoPi.Coder
  alias OctoPi.Coder.Event.CompactionEnd
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event, as: ExtEvent
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Session.CompactionSummaryMessage, as: CoderCSM
  alias OctoPi.Coder.Session.Messages, as: SessionMessages
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.UIHost
  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.CombinedProvider
  alias OctoPi.TUI.Autocomplete.ExtensionCommandProvider
  alias OctoPi.TUI.Autocomplete.FilePathProvider
  alias OctoPi.TUI.Autocomplete.SlashCommandProvider
  alias OctoPi.TUI.Clipboard
  alias OctoPi.TUI.Components
  alias OctoPi.TUI.Components.AssistantMessage.TextBlock
  alias OctoPi.TUI.Components.AssistantMessage.ThinkingBlock
  alias OctoPi.TUI.Components.BashExecution
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: TUICSM
  alias OctoPi.TUI.Components.Container
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Components.Header
  alias OctoPi.TUI.Components.LoginDialog
  alias OctoPi.TUI.Components.ModelSelector
  alias OctoPi.TUI.Components.SelectList
  alias OctoPi.TUI.Components.SessionSelector
  alias OctoPi.TUI.Components.SettingsList
  alias OctoPi.TUI.Components.SettingsSelector
  alias OctoPi.TUI.Components.SummarizePrompt
  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Components.TreeSelector
  alias OctoPi.TUI.Components.TruncatedText
  alias OctoPi.TUI.Components.UserMessage
  alias OctoPi.TUI.Components.UserMessageSelector
  alias OctoPi.TUI.FooterData
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.Overlay
  alias OctoPi.TUI.Paste
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.RenderLoop
  alias OctoPi.TUI.Terminal
  alias OctoPi.TUI.Terminal.Image
  alias OctoPi.TUI.Terminal.RawMode
  alias OctoPi.TUI.Terminal.Resize
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Transcript
  alias OctoPi.TUI.Transcript.AssistantHeader
  alias OctoPi.TUI.Transcript.AssistantStatus
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.VDOM.LineBuf
  alias OctoPi.TUI.VDOM.Paint
  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          session: pid() | nil,
          sup: pid() | nil,
          render_loop: pid() | nil,
          terminal: pid() | nil,
          raw_mode_fn: (atom() -> :ok) | nil,
          skip_raw_mode: boolean(),
          send_sigtstp_fn: (-> :ok),
          keybindings: Keybindings.t() | nil,
          input: Components.Input.t(),
          transcript: Transcript.t(),
          footer: Footer.t(),
          footer_data: pid() | nil,
          theme: Theme.t() | nil,
          width: pos_integer(),
          height: pos_integer(),
          exit: boolean(),
          suspend_pending: boolean(),
          editor_pending: boolean(),
          thinking_level: atom(),
          model: Model.t() | nil,
          models: [Model.t()],
          model_selector: ModelSelector.t() | nil,
          login_dialog: LoginDialog.t() | nil,
          settings_selector: SettingsSelector.t() | nil,
          settings_list: SettingsList.t() | nil,
          session_selector: SessionSelector.t() | nil,
          user_message_selector: UserMessageSelector.t() | nil,
          tree_selector: TreeSelector.t() | nil,
          summarize_prompt: SummarizePrompt.t() | nil,
          select_list: SelectList.t() | nil,
          tools_expanded: boolean(),
          thinking_visible: boolean(),
          loader: Components.Loader.t() | nil,
          loader_stash: Components.Loader.t() | nil,
          is_compacting?: boolean(),
          compaction_queue: [String.t()],
          pending_steering: [String.t()],
          pending_follow_up: [String.t()],
          working_message: String.t() | nil,
          notification: String.t() | nil,
          banner: Header.t() | nil,
          loaded_resources: Components.Resources.t() | nil,
          expand_prompt_fn: (String.t() -> String.t()) | nil,
          ui_overrides: map(),
          dialog: tuple() | nil,
          custom_widget: {GenServer.from(), map()} | nil,
          extension_shortcuts: [{(Key.t() -> boolean()), (t() -> t())}],
          extensions: [Extension.t()],
          focused_component: :input | {:dialog, atom()} | {:overlay, atom()} | nil,
          turn_seq: non_neg_integer(),
          current_msg_id: String.t() | nil,
          current_has_tool_calls?: boolean()
        }

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct session: nil,
            sup: nil,
            render_loop: nil,
            terminal: nil,
            raw_mode_fn: nil,
            skip_raw_mode: false,
            send_sigtstp_fn: &__MODULE__.default_send_sigtstp/0,
            keybindings: nil,
            input: %Components.Input{},
            transcript: %Transcript{},
            footer: %Footer{},
            footer_data: nil,
            theme: nil,
            banner: nil,
            loaded_resources: nil,
            expand_prompt_fn: nil,
            width: 80,
            height: 24,
            exit: false,
            suspend_pending: false,
            editor_pending: false,
            thinking_level: :off,
            model: nil,
            models: [],
            model_selector: nil,
            login_dialog: nil,
            settings_selector: nil,
            settings_list: nil,
            session_selector: nil,
            user_message_selector: nil,
            tree_selector: nil,
            summarize_prompt: nil,
            select_list: nil,
            tools_expanded: false,
            thinking_visible: true,
            loader: nil,
            loader_stash: nil,
            is_compacting?: false,
            compaction_queue: [],
            pending_steering: [],
            pending_follow_up: [],
            working_message: nil,
            notification: nil,
            ui_overrides: %{},
            dialog: nil,
            custom_widget: nil,
            extension_shortcuts: [],
            extensions: [],
            focused_component: :input,
            # Streaming-tick coalescing (opi-4dx.3 / .13): block events
            # update the Transcript directly and stamp `streaming_tick_at`;
            # the eventual :timeout fires a single render rather than
            # one per delta.
            streaming_tick_at: nil,
            turn_seq: 0,
            current_msg_id: nil,
            current_has_tool_calls?: false

  @doc """
  Return the transcript entries (the data payload of each Transcript
  slot) in display order — oldest first. Provided for tests and
  introspection; renders should walk `state.transcript` directly via
  `Transcript.render/2`.
  """
  @spec transcript_entries(t()) :: [term()]
  def transcript_entries(%{transcript: %Transcript{} = t}) do
    t.order |> Enum.reverse() |> Enum.map(&Transcript.fetch_data!(t, &1))
  end

  @doc "Build a UIContext bound to `interactive_pid`. Delegates to `UIHost`."
  @spec build_ui_context(pid()) :: UIContext.t()
  def build_ui_context(interactive_pid) do
    UIHost.build_ui_context(interactive_pid)
  end

  @doc """
  Handle a UIContext request, returning `{new_state, reply}`.

  Getters return `{state, value}`. Setters return `{state, :ok}`.
  Blocking dialogs return `{state, :pending}` — the caller must
  wait for resolution through key events.
  """
  @impl UIHost
  @spec handle_ui_request(t(), term()) :: {t(), term()}
  def handle_ui_request(state, :get_editor_text), do: {state, state.input.value}
  def handle_ui_request(state, :get_tools_expanded), do: {state, state.tools_expanded}
  def handle_ui_request(state, :get_theme), do: {state, state.theme && state.theme.name}

  def handle_ui_request(state, :get_all_themes), do: {state, Theme.available_themes()}

  def handle_ui_request(%{theme: nil} = state, {:apply_fg, _color, text}), do: {state, text}
  def handle_ui_request(state, {:apply_fg, color, text}), do: {state, Theme.fg(state.theme, color, text)}

  def handle_ui_request(%{theme: nil} = state, {:apply_bg, _color, text}), do: {state, text}
  def handle_ui_request(state, {:apply_bg, color, text}), do: {state, Theme.bg(state.theme, color, text)}

  def handle_ui_request(state, {:set_editor_text, text}) do
    input = %{state.input | value: text, cursor: String.length(text)}
    {%{state | input: input}, :ok}
  end

  def handle_ui_request(state, {:paste_to_editor, text}) do
    {%{state | input: Components.Input.paste(state.input, text)}, :ok}
  end

  def handle_ui_request(state, {:set_tools_expanded, val}) do
    resources =
      case state.loaded_resources do
        %Components.Resources{} = r -> %{r | expanded: val}
        other -> other
      end

    {%{state | tools_expanded: val, loaded_resources: resources}, :ok}
  end

  def handle_ui_request(state, {:set_theme, name}) do
    theme_atom = if is_binary(name), do: String.to_atom(name), else: name
    mode = if state.theme, do: state.theme.mode, else: Theme.detect_color_mode()
    {%{state | theme: Theme.load_builtin(theme_atom, mode)}, :ok}
  end

  def handle_ui_request(state, {:notify, text}) do
    {%{state | notification: text}, :ok}
  end

  def handle_ui_request(state, {:set_working_message, msg}) do
    state = %{state | working_message: msg}

    state =
      case state.loader do
        %Components.Loader{} ->
          message = msg || default_working_message()
          %{state | loader: Components.Loader.set_message(state.loader, message)}

        nil ->
          state
      end

    {state, :ok}
  end

  def handle_ui_request(state, {:set_status, id, nil}) do
    footer = %{state.footer | extension_statuses: Map.delete(state.footer.extension_statuses, id)}
    {%{state | footer: footer}, :ok}
  end

  def handle_ui_request(state, {:set_status, id, text}) do
    footer = %{state.footer | extension_statuses: Map.put(state.footer.extension_statuses, id, text)}
    {%{state | footer: footer}, :ok}
  end

  def handle_ui_request(state, {:set_title, text}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :title, text)}, :ok}
  end

  def handle_ui_request(state, {:set_working_indicator, val}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :working_indicator, val)}, :ok}
  end

  def handle_ui_request(state, {:set_widget, w}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :widget, w)}, :ok}
  end

  def handle_ui_request(state, {:set_header, h}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :header, h)}, :ok}
  end

  def handle_ui_request(state, {:set_footer, f}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :footer, f)}, :ok}
  end

  def handle_ui_request(state, {:set_hidden_thinking_label, label}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :hidden_thinking_label, label)}, :ok}
  end

  def handle_ui_request(state, {:set_editor_component, c}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :editor_component, c)}, :ok}
  end

  def handle_ui_request(state, {:add_autocomplete_provider, provider}) do
    alias OctoPi.TUI.Autocomplete.ExtensionProvider

    ext_provider = ExtensionProvider.new(provider)
    current = state.input.autocomplete_provider
    combined = ExtensionProvider.add_provider(current, ext_provider)
    input = %{state.input | autocomplete_provider: combined}
    {%{state | input: input}, :ok}
  end

  def handle_ui_request(state, {:select, options, opts}) do
    items = Enum.map(options, &select_list_item/1)
    sl = %SelectList{items: items, selected: Keyword.get(opts, :initial, 0)}
    new_state = focus(%{state | dialog: {:select, nil, options, opts}, select_list: sl}, {:dialog, :select_list})
    {new_state, :pending}
  end

  def handle_ui_request(state, {:confirm, prompt, opts}) do
    {%{state | dialog: {:confirm, nil, prompt, opts}}, :pending}
  end

  def handle_ui_request(state, {:input, prompt, opts}) do
    {%{state | dialog: {:input, nil, prompt, opts}}, :pending}
  end

  def handle_ui_request(state, {:editor, content, opts}) do
    {%{state | dialog: {:editor, nil, content, opts}}, :pending}
  end

  def handle_ui_request(state, {:register_extension_tool, spec}) do
    if state.session, do: Coder.add_tool(state.session, spec)
    {state, :ok}
  end

  def handle_ui_request(state, {:custom, _factory, _opts}) do
    {state, :pending}
  end

  @doc """
  Load user keybindings from `~/.octo_pi/keybindings.json`, falling
  back to defaults when the file is absent or unparseable.

  Accepts `:keybindings_path` in opts to override the default path
  (useful in tests).
  """
  @spec load_keybindings(keyword()) :: Keybindings.t()
  def load_keybindings(opts \\ []) do
    path = Keyword.get(opts, :keybindings_path, default_keybindings_path())
    load_keybindings_from_path(path)
  end

  defp default_keybindings_path do
    Path.join([System.user_home!(), ".octo_pi", "keybindings.json"])
  end

  defp load_keybindings_from_path(nil), do: Keybindings.new()

  defp load_keybindings_from_path(path) do
    case File.read(path) do
      {:error, _} ->
        Keybindings.new()

      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, overrides} when is_map(overrides) -> Keybindings.new(overrides)
          _ -> Keybindings.new()
        end
    end
  end

  @type run_opts :: [
          model: Model.t(),
          cwd: String.t(),
          tools: [OctoPi.Agent.Tool.t()],
          transport: module(),
          system_prompt: String.t() | nil,
          continue: boolean(),
          models: [Model.t()],
          extensions: [Extension.t()],
          resource_loader: OctoPi.Coder.ResourceLoader.t(),
          keybindings_path: Path.t() | nil,
          expand_prompt_fn: (String.t() -> String.t()) | nil,
          dimensions: {pos_integer(), pos_integer()},
          write_fn: (iodata() -> term()),
          raw_mode_fn: (:enter | :exit -> term()),
          skip_raw_mode: boolean(),
          skip_sigwinch: boolean(),
          auto_start_reader: boolean(),
          tty_fn: (-> term()),
          open_editor_fn: (String.t() -> term()),
          send_sigtstp_fn: (-> term()),
          debug_render: boolean(),
          terminal_name: GenServer.name() | nil,
          name: GenServer.name()
        ]

  @doc """
  Entry point for the CLI. Starts the Interactive GenServer, then
  blocks until it exits.

  Required: `:model`. All others are optional.
  """
  @spec run(run_opts()) :: :ok
  def run(opts) do
    {:ok, pid} = GenServer.start_link(__MODULE__, opts, gen_opts(opts))
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    end
  end

  defp gen_opts(opts), do: gen_opts_for_name(Keyword.get(opts, :name))
  defp gen_opts_for_name(nil), do: []
  defp gen_opts_for_name(name), do: [name: name]

  # --- GenServer callbacks ---

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {w, h} = Keyword.get_lazy(opts, :dimensions, &detect_dimensions/0)
    write_fn = Keyword.get(opts, :write_fn, &IO.write/1)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.fetch!(opts, :model)
    raw_mode_fn = Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1)
    skip_raw_mode = Keyword.get(opts, :skip_raw_mode, false)

    if Keyword.get(opts, :debug_render, false) do
      path = Path.join(cwd, "debug_render.log")
      {:ok, fd} = File.open(path, [:write, :utf8])
      Process.put(:debug_render_log, fd)
    end

    extensions = load_extensions(opts, cwd)
    session = start_sessions(opts, extensions)

    terminal_opts = build_terminal_opts(opts, write_fn)

    children = [
      %{id: Terminal, start: {Terminal, :start_link, [terminal_opts]}},
      %{id: FooterData, start: {FooterData, :start_link, [[cwd: cwd]]}}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_all, max_restarts: 0)

    terminal = child_pid(sup, Terminal)

    {:ok, render_loop} =
      RenderLoop.start_link(width: w, height: h, terminal: terminal, csi_2026?: true)

    footer_data = child_pid(sup, FooterData)

    :ok = Terminal.open(terminal)
    Coder.subscribe(session, self(), :async)

    theme = Theme.load_builtin(:dark, Theme.detect_color_mode())

    %{enabled: auto_compact_enabled?} = Coder.get_compaction_settings(session)

    footer = %Footer{
      cwd: cwd,
      model_id: model.id,
      provider: model.provider,
      context_percent: 0.0,
      context_window: model.context_window,
      auto_compact_enabled?: auto_compact_enabled?,
      git_branch: FooterData.get_git_branch(footer_data),
      # Show thinking level if model supports reasoning
      thinking_level: if(model.reasoning, do: thinking_level_label(:off))
    }

    # Check tmux configuration and warn if extended-keys-format is not set to csi-u
    notification = check_tmux_config()

    loaded_resources = build_loaded_resources(opts, extensions)
    keybindings = load_keybindings(Keyword.take(opts, [:keybindings_path]))

    state = %__MODULE__{
      session: session,
      sup: sup,
      render_loop: render_loop,
      terminal: terminal,
      raw_mode_fn: raw_mode_fn,
      skip_raw_mode: skip_raw_mode,
      send_sigtstp_fn: Keyword.get(opts, :send_sigtstp_fn, &__MODULE__.default_send_sigtstp/0),
      keybindings: keybindings,
      input: %Components.Input{
        width: w,
        height: h,
        theme: theme,
        autocomplete_provider: build_autocomplete_provider(loaded_resources, extensions)
      },
      width: w,
      height: h,
      theme: theme,
      banner: Header.new(theme, model: model.id, keybindings: keybindings),
      footer: footer,
      footer_data: footer_data,
      loaded_resources: loaded_resources,
      notification: notification,
      expand_prompt_fn: Keyword.get(opts, :expand_prompt_fn),
      model: model,
      models: Keyword.get(opts, :models, []),
      extensions: extensions
    }

    register_extension_tools(extensions, session)
    fire_session_start(extensions, cwd, self())

    {:ok, state, {:continue, :first_render}}
  end

  @impl GenServer
  def handle_continue(:first_render, state) do
    state = send_render(state)
    {:noreply, state, compute_timeout(state)}
  end

  @impl GenServer
  def handle_info({:hid_event, %Resize{width: w, height: h} = event}, state) do
    send(state.render_loop, {:resize, w, h})

    state
    |> handle_event(event)
    |> advance()
  end

  def handle_info({:hid_event, %Resize{width: w, height: h} = event, _mono_us}, state) do
    send(state.render_loop, {:resize, w, h})

    state
    |> handle_event(event)
    |> advance()
  end

  def handle_info({:hid_event, event}, state) do
    state
    |> Map.put(:notification, nil)
    |> handle_event(event)
    |> advance()
  end

  def handle_info({:hid_event, event, _mono_us}, state) do
    state
    |> Map.put(:notification, nil)
    |> handle_event(event)
    |> advance()
  end

  # opi-4dx.3 + .6: block-delta per-chunk path is intentionally cheap.
  # handle_event stashes into streaming_blocks; we skip advance() (no
  # render) and return only with an updated timeout so the streaming
  # tick will fire.
  def handle_info({:octo_pi_agent_event, %ev{}} = agent_msg, state)
      when ev in [Event.MessageBlockStart, Event.MessageBlockDelta, Event.MessageBlockEnd] do
    new_state =
      state
      |> handle_event(agent_msg)
      |> drain_block_deltas()

    {:noreply, new_state, compute_timeout(new_state)}
  end

  def handle_info({:octo_pi_agent_event, _} = agent_msg, state) do
    state
    |> handle_event(agent_msg)
    |> advance()
  end

  def handle_info({:extension_result, text}, state) do
    advance(%{state | notification: text})
  end

  def handle_info({:custom_done, from, result}, %{custom_widget: {from, _}} = state) do
    GenServer.reply(from, result)
    advance(%{state | custom_widget: nil})
  end

  def handle_info(:force_render, state) do
    advance(state)
  end

  def handle_info({:bash_done, _id, _output, _exit_code} = msg, state) do
    state
    |> handle_event(msg)
    |> advance()
  end

  # Single :timeout multiplexes loader-tick and streaming-tick
  # (opi-4dx.3). Both may be due simultaneously; flush streaming first
  # so the loader animation is anchored to the freshly-rendered frame.
  def handle_info(:timeout, state) do
    now = System.monotonic_time(:millisecond)

    state
    |> maybe_flush_streaming_tick(now)
    |> advance()
  end

  def handle_info({:EXIT, pid, _reason}, %{sup: sup} = state) when pid == sup do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state, compute_timeout(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state, compute_timeout(state)}
  end

  defp maybe_flush_streaming_tick(state, now) do
    if streaming_tick_due?(state, now) do
      flush_pending_partial(state)
    else
      state
    end
  end

  @impl GenServer
  def handle_call({:ui_request, {:custom, factory, _kw}}, from, state) do
    interactive_pid = self()
    tui = %{request_render: fn -> send(interactive_pid, :force_render) end}
    theme = build_custom_theme(state)
    done = fn result -> send(interactive_pid, {:custom_done, from, result}) end
    component = factory.(tui, theme, done)
    new_state = send_render(%{state | custom_widget: {from, component}})
    {:noreply, new_state, compute_timeout(new_state)}
  end

  def handle_call({:ui_request, msg}, from, state) do
    {new_state, reply} = handle_ui_request(state, msg)

    new_state =
      case reply do
        :pending -> put_dialog_from(new_state, from)
        _ -> new_state
      end

    new_state = send_render(new_state)

    case reply do
      :pending -> {:noreply, new_state, compute_timeout(new_state)}
      val -> {:reply, val, new_state, compute_timeout(new_state)}
    end
  end

  @impl GenServer
  def handle_cast({:ui_fire, ui_msg}, state) do
    {new_state, _reply} = handle_ui_request(state, ui_msg)
    advance(new_state)
  end

  @impl GenServer
  def terminate(_reason, state) do
    # Move cursor past the last rendered line so the shell prompt appears
    # on a fresh line below the content (mirrors upstream pi-mono stop()).
    if pid = state.render_loop, do: send(pid, :stop)

    # Synchronously shut the supervisor down so Terminal.terminate/2
    # (and through it Reader.terminate/2) runs before we return —
    # otherwise the BEAM proceeds to halt while the kitty/MOK disable
    # sequences and raw-mode exit are still queued, and the user's
    # shell inherits a TTY in kitty mode.
    if state.sup && Process.alive?(state.sup) do
      Supervisor.stop(state.sup, :normal, :infinity)
    end

    # Catastrophe path: if Terminal was already killed brutally (e.g.
    # :kill'd outside the normal stop chain), Reader's terminate never
    # ran, so kick raw-mode exit ourselves as a backstop. Bracketed
    # paste / kitty bytes are unrecoverable in that case.
    if terminal_dead?(state.terminal), do: safe_raw_mode_exit(state)

    if fd = Process.get(:debug_render_log) do
      File.close(fd)
      Process.delete(:debug_render_log)
    end

    :ok
  end

  defp terminal_dead?(nil), do: false
  defp terminal_dead?(pid) when is_pid(pid), do: not Process.alive?(pid)

  defp safe_raw_mode_exit(%{skip_raw_mode: true}), do: :ok

  defp safe_raw_mode_exit(%{raw_mode_fn: fun}) do
    fun.(:exit)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  # --- private helpers ---

  @loader_interval_ms 80

  # Floor on render rate. With cadence-driven scheduling two animated
  # components could converge to a tighter rate; clamp to ~60Hz.
  @min_render_interval_ms 16

  # Multiplexed deadline: the GenServer holds a single :timeout. Compute
  # the minimum remaining ms across (loader tick, streaming-coalescer
  # tick); :infinity if neither is armed. Replaces the old
  # `loader_timeout/1` to add streaming-tick coordination (opi-4dx.3).
  defp compute_timeout(state) do
    now = System.monotonic_time(:millisecond)

    deadlines =
      Enum.reject(
        [
          loader_deadline_ms(state),
          streaming_tick_remaining_ms(state, now)
        ],
        &is_nil/1
      )

    case deadlines do
      [] -> :infinity
      ms_list -> max(@min_render_interval_ms, Enum.min(ms_list))
    end
  end

  defp loader_deadline_ms(%{loader: %Components.Loader{}}), do: @loader_interval_ms
  defp loader_deadline_ms(_), do: nil

  defp streaming_tick_remaining_ms(%{streaming_tick_at: nil}, _now), do: nil
  defp streaming_tick_remaining_ms(%{streaming_tick_at: at}, now), do: max(0, at - now)

  defp put_dialog_from(%{dialog: {type, nil, a, b}} = state, from), do: %{state | dialog: {type, from, a, b}}

  defp put_dialog_from(state, _from), do: state

  defp advance(%{exit: true} = state), do: {:stop, :normal, state}

  defp advance(state) do
    state = handle_suspend(state)
    state = maybe_launch_editor(state)
    state = send_render(state)
    {:noreply, state, compute_timeout(state)}
  end

  defp detect_dimensions do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows() do
      {cols, rows}
    else
      _ -> {80, 24}
    end
  end

  defp default_raw_mode(:enter), do: RawMode.enter()
  defp default_raw_mode(:exit), do: RawMode.exit()

  defp check_tmux_config do
    if System.get_env("TMUX"), do: tmux_extended_keys_warning()
  end

  defp tmux_extended_keys_warning do
    case System.cmd("tmux", ["show-option", "-w", "extended-keys-format"]) do
      {output, 0} -> tmux_warning_for_output(output)
      _ -> nil
    end
  end

  defp tmux_warning_for_output(output) do
    if String.contains?(output, "csi-u") do
      nil
    else
      [current_format] = Regex.run(~r/\S+$/, output)

      "Warning: tmux extended-keys-format is #{current_format}. Pi works best with csi-u. Add 'set -g extended-keys-format csi-u' to ~/.tmux.conf and restart tmux."
    end
  end

  defp start_sessions(opts, extensions) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.fetch!(opts, :model)
    tools = Keyword.get_lazy(opts, :tools, fn -> Coder.default_tools(cwd) end)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        Coder.SystemPrompt.render(cwd: cwd, tools: tools)
      end)

    if Keyword.get(opts, :continue, false) do
      resume_or_new(cwd, model, tools, system_prompt, extensions, opts)
    else
      new_session(cwd, model, tools, system_prompt, extensions, opts)
    end
  end

  defp new_session(cwd, model, tools, system_prompt, extensions, opts) do
    session_id = new_session_id()
    {:ok, store_pid} = SessionStore.start_link(id: session_id, cwd: cwd)
    start_session(store_pid, model, tools, system_prompt, extensions, opts)
  end

  defp resume_or_new(cwd, model, tools, system_prompt, extensions, opts) do
    session_dir = SessionStore.session_dir(cwd)

    case SessionManager.find_recent(session_dir) do
      nil ->
        new_session(cwd, model, tools, system_prompt, extensions, opts)

      path ->
        {:ok, store_pid} = SessionStore.start_link(path: path)
        start_session(store_pid, model, tools, system_prompt, extensions, opts)
    end
  end

  defp start_session(store_pid, model, tools, system_prompt, extensions, opts) do
    agent_opts =
      put_if_present(
        [
          model: model,
          tools: tools,
          system_prompt: system_prompt,
          convert_to_llm: &SessionMessages.to_llm/1
        ],
        :transport,
        opts[:transport]
      )

    {:ok, agent_pid} = OctoPi.Agent.start_loop(agent_opts)

    {:ok, coder_pid} =
      Coder.start_loop(
        extensions: extensions,
        store_pid: store_pid,
        agent_pid: agent_pid,
        model_provider: fn -> model end
      )

    coder_pid
  end

  defp new_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    "~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b"
    |> :io_lib.format([a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp put_if_present(kw, _k, nil), do: kw
  defp put_if_present(kw, k, v), do: Keyword.put(kw, k, v)

  @doc false
  @spec build_autocomplete_provider(map() | nil, [Extension.t()]) :: CombinedProvider.t()
  def build_autocomplete_provider(loaded_resources, extensions \\ []) do
    template_commands =
      case loaded_resources do
        %Components.Resources{prompts: %Components.Resources.Prompts{templates: templates}} ->
          Enum.map(templates, fn t ->
            %Autocomplete.SlashCommand{name: t.name, description: "Prompt template"}
          end)

        _ ->
          []
      end

    registered = Dispatcher.get_registered_commands(extensions)

    extension_commands =
      Enum.map(registered, fn entry ->
        %Autocomplete.SlashCommand{
          name: entry.invocation_name,
          description: entry.cmd.description
        }
      end)

    slash_provider =
      SlashCommandProvider.new(Autocomplete.builtin_commands() ++ template_commands ++ extension_commands)

    builtin_names = MapSet.new(Autocomplete.builtin_commands(), & &1.name)
    ext_cmd_tuples = Enum.map(registered, fn entry -> {entry.invocation_name, entry.cmd, entry.ext_id} end)
    ext_cmd_provider = ExtensionCommandProvider.new(ext_cmd_tuples, builtin_names)

    file_provider = FilePathProvider.new(cwd: File.cwd!(), max_results: 50)

    CombinedProvider.new([slash_provider, ext_cmd_provider, file_provider])
  end

  defp build_loaded_resources(opts, extensions) do
    case Keyword.get(opts, :resource_loader) do
      nil ->
        nil

      loader ->
        Components.Resources.new(%{
          context_files: Enum.map(loader.context_files, &%{path: &1.path}),
          skills: Enum.map(loader.skills, &%{name: &1.name}),
          prompt_templates: Enum.map(loader.prompt_templates, &%{name: &1.name}),
          extensions: Enum.map(extensions, &%{name: &1.id})
        })
    end
  end

  defp load_extensions(opts, cwd) do
    case Keyword.get(opts, :extensions) do
      nil ->
        cwd
        |> Loader.standard_dirs()
        |> Loader.discover_all()
        |> Loader.load_all()

      exts when is_list(exts) ->
        exts
    end
  end

  defp register_extension_tools(extensions, coder_session) do
    for ext <- extensions, tool <- Map.values(ext.tools) do
      Coder.add_tool(coder_session, tool)
    end

    :ok
  end

  defp fire_session_start([], _cwd, _interactive_pid), do: :ok

  defp fire_session_start(extensions, cwd, interactive_pid) do
    ctx = Context.new(%{cwd: cwd, has_ui?: true, ui: build_ui_context(interactive_pid)})
    Dispatcher.emit(extensions, ExtEvent.new(:session_start, %{reason: :startup}), ctx)
  end

  defp fire_extension_event(extensions, event_type, state, payload \\ %{})
  defp fire_extension_event([], _event_type, _state, _payload), do: :ok

  defp fire_extension_event(extensions, event_type, state, payload) do
    interactive_pid = self()
    cwd = state.footer.cwd

    Task.start(fn ->
      ctx = Context.new(%{cwd: cwd, has_ui?: true, ui: build_ui_context(interactive_pid)})
      Dispatcher.emit(extensions, ExtEvent.new(event_type, payload), ctx)
    end)

    :ok
  end

  defp build_terminal_opts(opts, write_fn) do
    opts
    |> Keyword.take([
      :skip_raw_mode,
      :skip_sigwinch,
      :auto_start_reader,
      :dimensions,
      :raw_mode_fn,
      :tty_fn,
      :open_editor_fn
    ])
    |> Keyword.put(:name, Keyword.get(opts, :terminal_name, Terminal))
    |> Keyword.put(:write_fn, write_fn)
  end

  defp child_pid(sup, id) do
    {^id, pid, _, _} =
      Enum.find(Supervisor.which_children(sup), fn {child_id, _, _, _} -> child_id == id end)

    pid
  end

  # Suspend cycles the Terminal: close (deactivates → cooked mode for
  # the parent shell) → SIGTSTP → open (re-activates after fg).
  defp handle_suspend(%{suspend_pending: true} = state) do
    Terminal.close(state.terminal)
    state.send_sigtstp_fn.()
    Terminal.open(state.terminal)
    %{state | suspend_pending: false}
  end

  defp handle_suspend(state), do: state

  @doc false
  def default_send_sigtstp do
    if match?({:unix, _}, :os.type()) do
      System.cmd("kill", ["-TSTP", List.to_string(:os.getpid())])
    end

    :ok
  end

  defp maybe_launch_editor(%{editor_pending: false} = state), do: state

  defp maybe_launch_editor(%{editor_pending: true} = state) do
    state = %{state | editor_pending: false}

    case Terminal.open_editor(state.terminal, state.input.value) do
      {:ok, new_text} ->
        input = %{state.input | value: new_text, cursor: String.length(new_text)}
        %{state | input: input}

      {:error, :no_editor} ->
        %{state | notification: "No $EDITOR or $VISUAL configured"}

      {:error, _} ->
        state
    end
  end

  defp send_render(state) do
    input = Components.Input.update_scroll(state.input, state.width)
    state = %{state | input: input}
    input_lines = Components.Input.render(input, state.width)
    input_vnode = %VDOM.VLines{lines: input_lines}
    {lines, layout, state} = build_screen(state, input_vnode)
    lines = composite_active_overlay(state, lines)

    case Process.get(:debug_render_log) do
      nil -> :ok
      fd -> log_overwide(fd, lines, state.width)
    end

    cursor_seq = cursor_position(state, input_lines, lines, layout)
    send(state.render_loop, {:render, lines, cursor_seq})
    state
  end

  defp composite_active_overlay(%{model_selector: ms, width: w, height: h}, lines) when not is_nil(ms) do
    ov_w = min(60, w)
    ov_lines = ModelSelector.render(ms, ov_w)
    ov = %Overlay{lines: ov_lines, anchor: :center, width: ov_w, margin: 2}
    Overlay.composite(lines, [ov], w, h)
  end

  defp composite_active_overlay(
         %{focused_component: {:dialog, :tree_selector}, tree_selector: ts, width: w, height: h},
         _lines
       )
       when not is_nil(ts) do
    ts_lines = TreeSelector.render(ts, w)
    len = length(ts_lines)
    if len < h, do: ts_lines ++ List.duplicate("", h - len), else: Enum.take(ts_lines, h)
  end

  defp composite_active_overlay(%{focused_component: {:dialog, key}, width: w, height: h} = state, lines) do
    ov_w = min(70, w)

    case render_dialog_overlay(state, key, ov_w) do
      nil -> lines
      ov_lines -> Overlay.composite(lines, [%Overlay{lines: ov_lines, anchor: :center, width: ov_w, margin: 2}], w, h)
    end
  end

  defp composite_active_overlay(_state, lines), do: lines

  defp render_dialog_overlay(%{login_dialog: d}, :login, w) when not is_nil(d), do: LoginDialog.render(d, w)

  defp render_dialog_overlay(%{settings_selector: d}, :settings, w) when not is_nil(d),
    do: SettingsSelector.render(d, w)

  defp render_dialog_overlay(%{settings_list: d}, :settings_list, w) when not is_nil(d), do: SettingsList.render(d, w)

  defp render_dialog_overlay(%{session_selector: d}, :session_selector, w) when not is_nil(d),
    do: SessionSelector.render(d, w)

  defp render_dialog_overlay(%{user_message_selector: d}, :user_message_selector, w) when not is_nil(d),
    do: UserMessageSelector.render(d, w)

  defp render_dialog_overlay(%{tree_selector: d}, :tree_selector, w) when not is_nil(d), do: TreeSelector.render(d, w)

  defp render_dialog_overlay(%{summarize_prompt: d}, :summarize_prompt, w) when not is_nil(d),
    do: SummarizePrompt.render(d, w)

  defp render_dialog_overlay(%{select_list: d}, :select_list, w) when not is_nil(d), do: SelectList.render(d, w)
  defp render_dialog_overlay(_, _, _), do: nil

  defp log_overwide(fd, lines, width) do
    overwide =
      lines
      |> Enum.with_index()
      |> Enum.filter(fn {line, _idx} -> WrapAnsi.visible_width(line) > width end)

    if overwide != [] do
      ts = :erlang.system_time(:millisecond)
      IO.write(fd, "--- frame #{ts} width=#{width} ---\n")

      Enum.each(overwide, fn {line, idx} ->
        vw = WrapAnsi.visible_width(line)
        stripped = String.replace(line, ~r/\e\[[0-9;]*m/, "")
        IO.write(fd, "  [#{idx}] vw=#{vw} #{inspect(String.slice(stripped, 0, 120))}\n")
      end)
    end
  end

  defp cursor_position(%__MODULE__{custom_widget: cw}, _input_lines, _lines, _layout) when not is_nil(cw), do: "\e[?25l"

  defp cursor_position(%__MODULE__{focused_component: {:dialog, :tree_selector}}, _input_lines, _lines, _layout),
    do: "\e[?25l"

  defp cursor_position(%__MODULE__{input: input, width: width, height: height}, input_lines, lines, %{
         footer_height: footer_height,
         dropdown_height: dropdown_height,
         notification_height: notification_height
       }) do
    {crow, ccol} = Components.Input.cursor_rc(input, width)
    post_input_h = dropdown_height + notification_height
    input_end = length(lines) - footer_height - post_input_h
    input_start = input_end - length(input_lines)
    viewport_top = max(0, length(lines) - height)
    screen_row = input_start + crow - viewport_top + 1
    "\e[#{screen_row};#{ccol + 1}H"
  end

  # --- keybindings dispatch helpers ---

  @app_action_priority ~w(
    app.interrupt
    app.clear
    app.exit
    app.suspend
    app.thinking.toggle
    app.thinking.cycle
    app.tools.expand
    app.editor.external
    app.message.dequeue
    app.message.followUp
    app.model.cycleForward
    app.model.cycleBackward
    app.model.select
    app.clipboard.pasteImage
  )

  defp get_keybindings(%{keybindings: nil}), do: Keybindings.new()
  defp get_keybindings(%{keybindings: kb}), do: kb

  defp find_app_action(kb, key) do
    Enum.find(@app_action_priority, fn action -> Keybindings.matches?(kb, key, action) end)
  end

  # --- pure state-machine ---

  @doc """
  Apply an event to a state and return the updated state.
  Events:
    * `%Key{}` — keyboard input (all keys including printable chars).
    * `%Paste{}` — paste event from a human input device.
    * `%Resize{}` — terminal resize.
    * `{:octo_pi_agent_event, event}` — from the Agent subscription.
  """
  @spec handle_event(t(), term()) :: t()

  def handle_event(state, %Key{event_type: :release}), do: state

  def handle_event(%{custom_widget: {_, component}} = state, %Key{} = key) when not is_nil(component) do
    component.handle_input.(key)
    state
  end

  def handle_event(state, %Key{} = key), do: dispatch_key_to_focused(state, key)

  def handle_event(%{input: input} = state, %Paste{content: content}) when is_binary(content),
    do: %{state | input: Components.Input.paste(input, content)}

  def handle_event(state, {:octo_pi_agent_event, %Event.AgentStart{}}) do
    fire_extension_event(state.extensions, :agent_start, state)
    message = state.working_message || default_working_message()
    %{state | loader: Components.Loader.new(message: message)}
  end

  # opi-tze.3: keep the in-state copy of the steering / follow-up
  # queue snapshots in sync with the agent. Fires on every queue
  # mutation (enqueue, public-API drain, in-loop drain). The
  # pending-messages indicator above the editor renders directly
  # from these fields.
  def handle_event(state, {:octo_pi_agent_event, %Event.QueueUpdate{} = ev}) do
    %{
      state
      | pending_steering: Enum.map(ev.steering, &message_text/1),
        pending_follow_up: Enum.map(ev.follow_up, &message_text/1)
    }
  end

  def handle_event(state, {:octo_pi_agent_event, %OctoPi.Coder.Event.CompactionStart{reason: reason}}) do
    # Stash the existing loader (e.g. "Thinking…" if mid-run); restore
    # on CompactionEnd. Mirrors upstream's compaction_start handling.
    label = compaction_label(reason)
    new_loader = Components.Loader.new(message: label, cancellable: true)
    Terminal.set_progress(state.terminal, true)
    %{state | loader_stash: state.loader, loader: new_loader, is_compacting?: true}
  end

  def handle_event(state, {:octo_pi_agent_event, %CompactionEnd{result: {:ok, %{result: result}}} = ev}) do
    Terminal.set_progress(state.terminal, false)

    csm =
      TUICSM.new(CoderCSM.new(result.summary, result.tokens_before, DateTime.to_iso8601(DateTime.utc_now())))

    state = %{
      state
      | loader: state.loader_stash,
        loader_stash: nil,
        is_compacting?: false,
        transcript: append_csm(state.transcript, csm),
        footer: update_footer(state.footer, ev)
    }

    flush_compaction_queue(state)
  end

  def handle_event(state, {:octo_pi_agent_event, %CompactionEnd{} = ev}) do
    Terminal.set_progress(state.terminal, false)

    state = %{
      state
      | loader: state.loader_stash,
        loader_stash: nil,
        is_compacting?: false,
        footer: update_footer(state.footer, ev)
    }

    flush_compaction_queue(state)
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.AgentEnd{} = event}) do
    fire_extension_event(state.extensions, :agent_end, state)

    %{
      state
      | loader: nil,
        working_message: nil,
        footer: update_footer(state.footer, event)
    }
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.TurnStart{turn: turn}}) do
    fire_extension_event(state.extensions, :turn_start, state, %{turn: turn})
    state
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.TurnEnd{turn: turn}}) do
    fire_extension_event(state.extensions, :turn_end, state, %{turn: turn})
    state
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.MessageStart{}}) do
    seq = state.turn_seq + 1
    msg_id = "turn-#{seq}"

    header = %AssistantHeader{msg_id: msg_id, has_tool_calls?: false}

    %{
      state
      | turn_seq: seq,
        current_msg_id: msg_id,
        current_has_tool_calls?: false,
        streaming_tick_at: nil,
        transcript: Transcript.append(state.transcript, header_key(msg_id), header)
    }
  end

  # opi-4dx.13: block events update the top-level Transcript directly,
  # keyed by `<msg_id>:<block_id>`. The streaming-tick deadline is stamped
  # so :timeout fires a single render pass per coalescing window rather
  # than re-rendering on every delta.
  def handle_event(state, {:octo_pi_agent_event, %Event.MessageBlockStart{block_id: id, kind: kind}}) do
    state
    |> stamp_streaming_tick()
    |> append_block(id, kind, "")
  end

  def handle_event(
        state,
        {:octo_pi_agent_event, %Event.MessageBlockDelta{block_id: id, kind: kind, snapshot: snapshot}}
      ) do
    state
    |> stamp_streaming_tick()
    |> upsert_block(id, kind, snapshot)
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.MessageBlockEnd{block_id: id, kind: kind, content: content}}) do
    state
    |> stamp_streaming_tick()
    |> upsert_block(id, kind, content)
    |> finalize_block(id)
  end

  def handle_event(state, {:octo_pi_agent_event, %MessageEnd{message: msg} = event}) do
    msg_id = state.current_msg_id || "turn-#{state.turn_seq}"
    has_tool_calls? = has_tool_calls?(msg)
    stop_reason = extract_stop_reason(msg)
    error_message = Map.get(msg, :error_message)

    status = %AssistantStatus{
      stop_reason: stop_reason,
      error_message: error_message,
      has_tool_calls?: has_tool_calls?
    }

    transcript = maybe_update_header_tool_flag(state.transcript, msg_id, has_tool_calls?)
    transcript = Transcript.append(transcript, status_key(msg_id), status)

    %{
      state
      | streaming_tick_at: nil,
        current_msg_id: nil,
        current_has_tool_calls?: false,
        transcript: transcript,
        footer: update_footer(state.footer, event)
    }
  end

  def handle_event(state, {:octo_pi_agent_event, event}) do
    %{
      state
      | transcript: update_transcript(state.transcript, event, state.theme),
        footer: update_footer(state.footer, event)
    }
  end

  def handle_event(state, %Resize{width: w, height: h}) do
    %{
      state
      | width: w,
        height: h,
        input: %{state.input | width: w, height: h},
        transcript: Transcript.invalidate(state.transcript)
    }
  end

  def handle_event(state, {:bash_done, id, output, exit_code}) do
    key = bash_key(id)

    case Transcript.get_data(state.transcript, key) do
      %BashExecution{} = be ->
        updated =
          be
          |> BashExecution.append_output(output)
          |> BashExecution.set_complete(exit_code)

        %{state | transcript: Transcript.replace(state.transcript, key, updated)}

      _ ->
        state
    end
  end

  def handle_event(state, _), do: state

  defp append_csm(transcript, csm) do
    Transcript.append(transcript, compaction_key(), csm)
  end

  defp handle_event_after_app(%{extension_shortcuts: [_ | _] = shortcuts} = state, key) do
    case try_extension_shortcut(shortcuts, key, state) do
      {:consumed, new_state} -> new_state
      :pass -> handle_event_key(state, key)
    end
  end

  defp handle_event_after_app(state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.interrupt", %{is_compacting?: true, session: session} = state, _key)
       when not is_nil(session) do
    Coder.abort_compact(session)
    state
  end

  # opi-tze.8: Escape (mapped to app.interrupt) while the agent is
  # streaming — drain queued messages back into the editor AND
  # abort the in-flight run, in one gesture. Mirrors upstream
  # interactive-mode.ts L2316-2321:
  #     if (this.loadingAnimation) {
  #       this.restoreQueuedMessagesToEditor({ abort: true });
  #     }
  # The non-empty-input case used to just clear the input; that's
  # subsumed by restore_queued_to_editor/2, which combines the
  # current editor text with whatever was queued (or leaves it
  # untouched when both queues are empty).
  defp dispatch_app_action("app.interrupt", %{loader: %Components.Loader{}} = state, _key) do
    {_n, state} = restore_queued_to_editor(state, abort?: true)
    state
  end

  defp dispatch_app_action("app.interrupt", state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.clear", %{input: %{value: v}} = state, _key) when v != "",
    do: %{state | input: %{state.input | value: "", cursor: 0}}

  defp dispatch_app_action("app.clear", %{is_compacting?: true, session: session} = state, _key)
       when not is_nil(session) do
    Coder.abort_compact(session)
    state
  end

  defp dispatch_app_action("app.clear", %{loader: %Components.Loader{}} = state, _key) do
    if state.session, do: Coder.abort(state.session)
    state
  end

  defp dispatch_app_action("app.clear", state, _key), do: %{state | transcript: %Transcript{}}

  defp dispatch_app_action("app.exit", %{input: %{value: ""}} = state, _key), do: %{state | exit: true}
  defp dispatch_app_action("app.exit", state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.suspend", state, _key), do: %{state | suspend_pending: true}

  defp dispatch_app_action("app.thinking.toggle", state, _key), do: %{state | thinking_visible: !state.thinking_visible}

  defp dispatch_app_action("app.thinking.cycle", state, _key) do
    new_level = next_thinking_level(state.thinking_level)
    if state.session, do: Coder.set_thinking_level(state.session, new_level)
    label = thinking_level_label(new_level)

    %{
      state
      | thinking_level: new_level,
        footer: %{state.footer | thinking_level: label},
        notification: "Thinking: #{new_level}"
    }
  end

  defp dispatch_app_action("app.tools.expand", state, _key) do
    expanded = !state.tools_expanded

    banner =
      case state.banner do
        %Header{} = b -> %{b | expanded: expanded}
        other -> other
      end

    resources =
      case state.loaded_resources do
        %Components.Resources{} = r -> %{r | expanded: expanded}
        other -> other
      end

    %{state | tools_expanded: expanded, banner: banner, loaded_resources: resources}
  end

  defp dispatch_app_action("app.editor.external", state, _key), do: %{state | editor_pending: true}

  defp dispatch_app_action("app.message.dequeue", %{session: nil} = state, _key), do: state

  # opi-tze.5: Restore queued steering and follow-up messages back
  # into the editor for free editing. Mirrors upstream pi-mono
  # `restoreQueuedMessagesToEditor/1` (interactive-mode.ts L3549-3568):
  # drain ALL queues, join the message texts with blank lines, then
  # combine with whatever the user has currently typed. The user can
  # then edit, delete, or resubmit the combined text however they like.
  defp dispatch_app_action("app.message.dequeue", state, _key) do
    case restore_queued_to_editor(state, abort?: false) do
      {0, state} -> %{state | notification: "No queued messages"}
      {_n, state} -> state
    end
  end

  defp dispatch_app_action("app.message.followUp", %{loader: %Components.Loader{}} = state, _key) do
    text = state.input.value

    if text == "" do
      state
    else
      result = if state.session, do: Coder.follow_up(state.session, text), else: :ok
      input = %{state.input | value: "", cursor: 0}

      notification =
        case result do
          {:error, :full} -> "Follow-up queue is full"
          _ -> "Follow-up queued"
        end

      %{state | input: input, notification: notification}
    end
  end

  defp dispatch_app_action("app.message.followUp", state, _key), do: handle_event_key(state, %Key{key: :enter})

  defp dispatch_app_action("app.model.cycleForward", %{models: []} = state, _key), do: state

  defp dispatch_app_action("app.model.cycleForward", state, _key) do
    new_model = cycle_model(state.models, state.model, :next)
    if state.session, do: Coder.set_model(state.session, new_model)

    %{
      state
      | model: new_model,
        footer: %{state.footer | model_id: new_model.id, provider: new_model.provider},
        notification: "Model: #{new_model.id}"
    }
  end

  defp dispatch_app_action("app.model.cycleBackward", %{models: []} = state, _key), do: state

  defp dispatch_app_action("app.model.cycleBackward", state, _key) do
    new_model = cycle_model(state.models, state.model, :prev)
    if state.session, do: Coder.set_model(state.session, new_model)

    %{
      state
      | model: new_model,
        footer: %{state.footer | model_id: new_model.id, provider: new_model.provider},
        notification: "Model: #{new_model.id}"
    }
  end

  defp dispatch_app_action("app.model.select", %{models: []} = state, _key), do: state

  defp dispatch_app_action("app.model.select", state, _key) do
    current_id = state.model && state.model.id
    ms = ModelSelector.new(state.models, state.theme, current: current_id)
    focus(%{state | model_selector: ms}, {:dialog, :model_selector})
  end

  defp dispatch_app_action("app.clipboard.pasteImage", state, _key) do
    case Clipboard.paste_image_from_clipboard() do
      {:ok, %{data: base64_data, mime_type: mime_type}} ->
        image_dims =
          case Image.get_image_dimensions(base64_data, mime_type) do
            {:ok, dims} -> dims
            :error -> %{width: 100, height: 100}
          end

        cell_dims = %{width_px: 9, height_px: 18}

        case Image.render_image(base64_data, image_dims, cell_dims: cell_dims, mime_type: mime_type) do
          {:ok, encoded, _rows} -> %{state | input: Components.Input.paste(state.input, encoded)}
          {:fallback, text} -> %{state | input: Components.Input.paste(state.input, text)}
        end

      :error ->
        state
    end
  end

  defp dispatch_app_action(_action, state, _key), do: state

  defp handle_event_key(%{input: %{value: ""}} = state, %Key{key: :escape}), do: %{state | exit: true}

  defp handle_event_key(%{input: input} = state, %Key{key: :escape}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  defp handle_event_key(%{input: input} = state, %Key{key: cp, modifiers: []}) when is_integer(cp),
    do: %{state | input: Components.Input.insert(input, <<cp::utf8>>)}

  # shift+printable: insert what the terminal said the user typed
  # (kitty CSI-u flag 4 reports it as `shifted_key`). Without that field
  # — modifyOtherKeys, legacy CSI, or kitty without flag 4 — we have no
  # layout-correct way to recover the shifted character on the wire,
  # so the keystroke falls through to keybinding dispatch unchanged.
  defp handle_event_key(%{input: input} = state, %Key{modifiers: [:shift], shifted_key: sk}) when is_integer(sk),
    do: %{state | input: Components.Input.insert(input, <<sk::utf8>>)}

  defp handle_event_key(%{input: input} = state, %Key{} = key) do
    kb = get_keybindings(state)

    case Components.Input.handle_key(input, key, kb) do
      {new_input, [{:submit, value}]} when value != "" -> handle_submit(state, new_input, value)
      {new_input, _events} -> %{state | input: new_input}
      new_input -> %{state | input: new_input}
    end
  end

  defp handle_submit(state, new_input, "/" <> command = value) do
    {cmd, cmd_args} =
      case String.split(String.trim(command), " ", parts: 2) do
        [name] -> {String.downcase(name), ""}
        [name, rest] -> {String.downcase(name), rest}
      end

    dispatch_slash(cmd, cmd_args, state, new_input, value)
  end

  defp handle_submit(state, new_input, "!" <> rest) do
    command = String.trim_leading(rest, " ")
    id = make_ref()
    be = BashExecution.new(command, id: id)
    interactive_pid = self()

    Task.start(fn ->
      {output, exit_code} = System.shell(command, stderr_to_stdout: true)
      send(interactive_pid, {:bash_done, id, output, exit_code})
    end)

    %{
      state
      | input: %{new_input | value: "", cursor: 0},
        transcript: Transcript.append(state.transcript, bash_key(id), be)
    }
  end

  defp handle_submit(state, new_input, value), do: do_handle_submit(state, new_input, value)

  defp dispatch_slash(cmd, cmd_args, state, new_input, _value)
       when cmd in ~w(help clear compact cost copy name session login model sessions settings scoped-models export import tree continue theme config new quit changelog hotkeys resume fork clone logout reload share) do
    dispatch_slash_command(cmd, cmd_args, %{state | input: %{new_input | value: "", cursor: 0}})
  end

  defp dispatch_slash(cmd, _cmd_args, state, new_input, value) do
    dispatch_ext_or_ai(Dispatcher.get_command_by_invocation(state.extensions, cmd), state, new_input, value)
  end

  defp dispatch_ext_or_ai({cmd_spec, _ext_id}, state, new_input, _value) do
    run_extension_command(cmd_spec, state, new_input)
  end

  defp dispatch_ext_or_ai(nil, state, new_input, value) do
    do_handle_submit(state, new_input, value)
  end

  defp run_extension_command(cmd_spec, state, new_input) do
    interactive_pid = self()
    cwd = state.footer.cwd

    Task.start(fn ->
      ctx = Context.new(%{cwd: cwd, has_ui?: true, ui: build_ui_context(interactive_pid)})
      result = cmd_spec.handler.("", ctx)
      notify_extension_result(interactive_pid, result)
    end)

    %{state | input: %{new_input | value: "", cursor: 0}}
  end

  defp notify_extension_result(pid, text) when is_binary(text), do: send(pid, {:extension_result, text})

  defp notify_extension_result(pid, list) when is_list(list) do
    text = list |> Enum.filter(&is_binary/1) |> Enum.join("\n")
    if text != "", do: send(pid, {:extension_result, text})
  end

  defp notify_extension_result(_pid, _), do: :ok

  defp do_handle_submit(%{is_compacting?: true} = state, new_input, value) do
    # Compaction in flight — queue the prompt and replay it via
    # flush_compaction_queue when CompactionEnd lands. Mirrors
    # upstream's queueCompactionMessage. The user message lands in
    # the transcript immediately so they have visual feedback that
    # their input was accepted.
    user_msg = UserMessage.new(value)

    %{
      state
      | input: %{new_input | value: "", cursor: 0},
        transcript: append_user_msg(state.transcript, user_msg),
        compaction_queue: state.compaction_queue ++ [value]
    }
  end

  # Submit while the agent is streaming — route to Coder.steer (the
  # default upstream "streamingBehavior" in agent-session.ts L987-997).
  # Previously this called Coder.prompt unconditionally, which the
  # Agent rejects with {:error, :already_streaming}; the rejection was
  # silently swallowed by the Task.start fork and the message was lost
  # while still being rendered in the local transcript.
  defp do_handle_submit(%{loader: %Components.Loader{}, session: session} = state, new_input, value)
       when not is_nil(session) do
    result = Coder.steer(session, value)

    user_msg = UserMessage.new(value)

    notification =
      case result do
        {:error, :full} -> "Steering queue is full"
        _ -> "Steered"
      end

    %{
      state
      | input: %{new_input | value: "", cursor: 0},
        transcript: append_user_msg(state.transcript, user_msg),
        notification: notification
    }
  end

  defp do_handle_submit(state, new_input, value) do
    send_text = if state.expand_prompt_fn, do: state.expand_prompt_fn.(value), else: value

    # Coder.prompt may run pre-prompt auto-compact synchronously
    # (LLM call), which would block the TUI's event loop and freeze
    # the screen. Fork the call so the TUI keeps processing
    # subscriber events (CompactionStart spinner, MessageEnd, etc.)
    # while the prompt is in flight. Errors propagate through the
    # subscribed agent-event stream.
    if state.session do
      session = state.session
      Task.start(fn -> Coder.prompt(session, value, send_text) end)
    end

    user_msg = UserMessage.new(value)
    %{state | input: %{new_input | value: "", cursor: 0}, transcript: append_user_msg(state.transcript, user_msg)}
  end

  defp dispatch_slash_command("clear", _args, state), do: %{state | transcript: %Transcript{}}

  defp dispatch_slash_command("new", _args, state),
    do: %{state | transcript: %Transcript{}, notification: "✓ New session started"}

  defp dispatch_slash_command("copy", _args, state) do
    case last_assistant_text(state.transcript) do
      nil ->
        %{state | notification: "No agent messages to copy yet"}

      text ->
        case copy_to_clipboard(text) do
          :ok -> %{state | notification: "Copied last agent message to clipboard"}
          {:error, reason} -> %{state | notification: "Copy failed: #{reason}"}
        end
    end
  end

  defp dispatch_slash_command("session", _args, state) do
    %{state | notification: build_session_info(state)}
  end

  defp dispatch_slash_command("name", "", state) do
    case state.footer.session_name do
      nil -> %{state | notification: "Usage: /name <session-name>"}
      name -> %{state | notification: "Session name: #{name}"}
    end
  end

  defp dispatch_slash_command("name", name, state) do
    %{state | footer: %{state.footer | session_name: name}, notification: "Session name set: #{name}"}
  end

  defp dispatch_slash_command("model", _args, state) do
    current_id = state.model && state.model.id
    ms = ModelSelector.new(state.models, state.theme, current: current_id)
    focus(%{state | model_selector: ms}, {:dialog, :model_selector})
  end

  defp dispatch_slash_command("help", _args, state),
    do: %{state | notification: "Commands: /clear /compact /cost /model /theme /config"}

  defp dispatch_slash_command("cost", _args, state) do
    f = state.footer

    msg =
      "$#{Float.round(f.cost, 4)} · ↑#{Footer.format_tokens(f.input_tokens)} ↓#{Footer.format_tokens(f.output_tokens)}"

    %{state | notification: msg}
  end

  defp dispatch_slash_command("compact", _args, state) do
    if state.session, do: Task.start(fn -> Coder.compact(state.session, []) end)
    state
  end

  defp dispatch_slash_command("theme", _args, state), do: %{state | notification: "Theme picker not yet implemented"}

  defp dispatch_slash_command("config", _args, state),
    do: %{state | notification: "Config: use --help for startup options"}

  defp dispatch_slash_command("login", _args, %{theme: nil} = state),
    do: %{state | notification: "No theme loaded — cannot open login dialog"}

  defp dispatch_slash_command("login", _args, state) do
    ld = LoginDialog.new(state.theme)
    focus(%{state | login_dialog: ld}, {:dialog, :login})
  end

  defp dispatch_slash_command("logout", _args, state) do
    providers = read_auth_providers()

    if providers == [] do
      %{state | notification: "No configured providers to log out from"}
    else
      items = Enum.map(providers, fn p -> %SelectList.Item{value: p, label: p} end)
      sl = %SelectList{items: items, selected: 0}
      focus(%{state | select_list: sl, dialog: {:select, :logout, providers, []}}, {:dialog, :select_list})
    end
  end

  defp dispatch_slash_command("settings", _args, %{theme: nil} = state),
    do: %{state | notification: "No theme loaded — cannot open settings"}

  defp dispatch_slash_command("settings", _args, state) do
    ss = SettingsSelector.new(state.theme)
    focus(%{state | settings_selector: ss}, {:dialog, :settings})
  end

  defp dispatch_slash_command("sessions", _args, %{theme: nil} = state),
    do: %{state | notification: "No theme loaded — cannot open session selector"}

  defp dispatch_slash_command("sessions", _args, state), do: open_session_selector(state)

  defp dispatch_slash_command("resume", _args, %{theme: nil} = state),
    do: %{state | notification: "No theme loaded — cannot open session selector"}

  defp dispatch_slash_command("resume", _args, state), do: open_session_selector(state)

  defp dispatch_slash_command("share", _args, state) do
    case System.find_executable("gh") do
      nil ->
        %{state | notification: "gh CLI not found — install from cli.github.com to enable sharing"}

      _gh ->
        text = export_transcript_text(state.transcript)
        tmp = Path.join(System.tmp_dir!(), "octo_pi_share_#{System.unique_integer([:positive])}.md")

        with :ok <- File.write(tmp, text),
             {output, 0} <- System.shell("gh gist create --public \"#{tmp}\" 2>&1") do
          File.rm(tmp)
          url = String.trim(output)
          %{state | notification: "Share URL: #{url}"}
        else
          _ ->
            File.rm(tmp)
            %{state | notification: "Share failed — check that gh is authenticated (run: gh auth login)"}
        end
    end
  end

  defp dispatch_slash_command("reload", _args, %{is_compacting?: true} = state) do
    %{state | notification: "Cannot reload while compaction is in progress"}
  end

  defp dispatch_slash_command("reload", _args, %{loader: loader} = state) when not is_nil(loader) do
    %{state | notification: "Cannot reload while loading is in progress"}
  end

  defp dispatch_slash_command("reload", _args, state) do
    keybindings = load_keybindings()
    banner = if state.banner, do: %{state.banner | keybindings: keybindings}, else: state.banner
    %{state | keybindings: keybindings, banner: banner, notification: "Reloaded keybindings"}
  end

  defp dispatch_slash_command("clone", _args, %{transcript: %Transcript{data: data}} = state)
       when map_size(data) == 0 do
    %{state | notification: "Nothing to clone yet"}
  end

  defp dispatch_slash_command("clone", _args, state) do
    %{state | notification: "Cloned to new session"}
  end

  defp dispatch_slash_command("fork", _args, %{theme: nil} = state),
    do: %{state | notification: "No theme loaded — cannot open fork selector"}

  defp dispatch_slash_command("fork", _args, state) do
    msgs = user_messages_for_fork(state.transcript)

    if msgs == [] do
      %{state | notification: "No messages to fork from"}
    else
      ums = UserMessageSelector.new(msgs, state.theme)
      focus(%{state | user_message_selector: ums}, {:dialog, :user_message_selector})
    end
  end

  defp dispatch_slash_command("scoped-models", _args, state),
    do: %{state | notification: "Scoped models: use /model to select, Ctrl+P to cycle"}

  defp dispatch_slash_command("export", _args, state),
    do: %{state | notification: "Export: use /sessions to save, or Ctrl+E for session export"}

  defp dispatch_slash_command("import", _args, state),
    do: %{state | notification: "Import: provide a session JSON to resume from a previous export"}

  defp dispatch_slash_command("tree", _args, %{session: nil} = state) do
    %{state | notification: "No active session for tree view"}
  end

  defp dispatch_slash_command("tree", _args, state) do
    roots = Coder.get_tree(state.session)

    ts =
      TreeSelector.new_from_tree(roots,
        leaf_id: state.current_msg_id,
        max_visible_lines: max(5, div(state.height, 2))
      )

    focus(%{state | tree_selector: ts}, {:dialog, :tree_selector})
  end

  defp dispatch_slash_command("hotkeys", _args, state) do
    kb = get_keybindings(state)
    k = fn action -> kb |> Keybindings.get_keys(action) |> Enum.join(" / ") end

    hotkeys = """
    **Navigation**
    | Key | Action |
    |-----|--------|
    | `#{k.("tui.editor.cursorUp")}` / `#{k.("tui.editor.cursorDown")}` / `#{k.("tui.editor.cursorLeft")}` / `#{k.("tui.editor.cursorRight")}` | Move cursor / browse history |
    | `#{k.("tui.editor.cursorWordLeft")}` / `#{k.("tui.editor.cursorWordRight")}` | Move by word |
    | `#{k.("tui.editor.cursorLineStart")}` | Start of line |
    | `#{k.("tui.editor.cursorLineEnd")}` | End of line |
    | `#{k.("tui.editor.pageUp")}` / `#{k.("tui.editor.pageDown")}` | Scroll by page |

    **Editing**
    | Key | Action |
    |-----|--------|
    | `#{k.("tui.input.submit")}` | Send message |
    | `#{k.("tui.input.newLine")}` | New line |
    | `#{k.("tui.editor.deleteWordBackward")}` | Delete word backwards |
    | `#{k.("tui.editor.deleteWordForward")}` | Delete word forwards |
    | `#{k.("tui.editor.deleteToLineStart")}` | Delete to start of line |
    | `#{k.("tui.editor.deleteToLineEnd")}` | Delete to end of line |
    | `#{k.("tui.editor.yank")}` | Paste most-recently-deleted text |
    | `#{k.("tui.editor.yankPop")}` | Cycle deleted text after pasting |
    | `#{k.("tui.editor.undo")}` | Undo |

    **Other**
    | Key | Action |
    |-----|--------|
    | `#{k.("tui.input.tab")}` | Path completion / accept autocomplete |
    | `#{k.("app.interrupt")}` | Cancel autocomplete / abort streaming |
    | `#{k.("app.clear")}` | Clear editor (first) / exit (second) |
    | `#{k.("app.exit")}` | Exit when editor is empty |
    | `#{k.("app.suspend")}` | Suspend to background |
    | `#{k.("app.thinking.cycle")}` | Cycle thinking level |
    | `#{k.("app.model.cycleForward")}` / `#{k.("app.model.cycleBackward")}` | Cycle models |
    | `#{k.("app.model.select")}` | Open model selector |
    | `#{k.("app.tools.expand")}` | Toggle tool output expansion |
    | `#{k.("app.thinking.toggle")}` | Toggle thinking block visibility |
    | `#{k.("app.editor.external")}` | Edit message in external editor |
    | `#{k.("app.message.followUp")}` | Queue follow-up message |
    | `#{k.("app.message.dequeue")}` | Restore queued messages |
    | `#{k.("app.clipboard.pasteImage")}` | Paste image from clipboard |
    | `/` | Slash commands |
    | `!` | Run bash command |
    """

    %{state | notification: String.trim(hotkeys)}
  end

  defp dispatch_slash_command("changelog", _args, state) do
    notification =
      case read_changelog_content() do
        nil ->
          "No changelog entries found."

        content ->
          sections = parse_changelog_sections(content)
          if sections == [], do: "No changelog entries found.", else: Enum.join(sections, "\n\n")
      end

    %{state | notification: notification}
  end

  defp dispatch_slash_command("quit", _args, state), do: %{state | exit: true}

  defp dispatch_slash_command("continue", _args, state) do
    if state.session do
      %{state | notification: "Continuing last action..."}
    else
      %{state | notification: "No active session to continue"}
    end
  end

  defp read_changelog_content do
    path = Path.join(File.cwd!(), "CHANGELOG.md")

    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp parse_changelog_sections(content) do
    content
    |> String.split("\n")
    |> Enum.reduce({[], []}, &reduce_changelog_line/2)
    |> then(fn {sections, current} ->
      if current == [], do: sections, else: sections ++ [current |> Enum.reverse() |> Enum.join("\n") |> String.trim()]
    end)
    |> Enum.reverse()
  end

  defp reduce_changelog_line(line, {sections, current}) do
    cond do
      String.starts_with?(line, "## ") and current == [] ->
        {sections, [line]}

      String.starts_with?(line, "## ") ->
        finished = current |> Enum.reverse() |> Enum.join("\n") |> String.trim()
        {sections ++ [finished], [line]}

      true ->
        {sections, [line | current]}
    end
  end

  defp append_user_msg(transcript, user_msg) do
    Transcript.append(transcript, user_key(), user_msg)
  end

  defp try_extension_shortcut([], _key, _state), do: :pass

  defp try_extension_shortcut([{match_fn, handler} | rest], key, state) do
    if match_fn.(key) do
      {:consumed, handler.(state)}
    else
      try_extension_shortcut(rest, key, state)
    end
  end

  # --- transcript updates ---

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.ToolExecutionStart} = ev, _theme) do
    te = ToolExecution.new(ev.tool_name, ev.tool_call_id, ev.args)
    Transcript.append(transcript, tool_key(ev.tool_call_id), te)
  end

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.ToolExecutionEnd} = ev, _theme) do
    key = tool_key(ev.tool_call_id)

    case Transcript.get_data(transcript, key) do
      %ToolExecution{} = te ->
        result_text = extract_tool_result_text(ev.result)
        is_error = Map.get(ev.result, :is_error?, false)
        updated = ToolExecution.set_result(te, result_text, is_error)
        Transcript.replace(transcript, key, updated)

      _ ->
        transcript
    end
  end

  defp update_transcript(transcript, _, _theme), do: transcript

  defp update_footer(footer, %{__struct__: MessageEnd, message: msg}) do
    usage = Map.get(msg, :usage, %{})
    cost_struct = Map.get(usage, :cost, %{})

    # `context_percent` reflects the LLM's current context size from
    # the latest assistant message (the same value `over_threshold?`
    # uses to decide auto-compact), NOT the cumulative work done
    # across the run. `input_tokens` etc. continue to accumulate for
    # the running totals display.
    context_tokens = current_context_tokens(usage)

    context_percent =
      if footer.context_window > 0 and is_integer(context_tokens),
        do: context_tokens / footer.context_window * 100.0,
        else: footer.context_percent

    %{
      footer
      | input_tokens: footer.input_tokens + Map.get(usage, :input, 0),
        output_tokens: footer.output_tokens + Map.get(usage, :output, 0),
        cache_read: footer.cache_read + Map.get(usage, :cache_read, 0),
        cache_write: footer.cache_write + Map.get(usage, :cache_write, 0),
        cost: footer.cost + Map.get(cost_struct, :total, 0.0),
        context_percent: context_percent
    }
  end

  # After compaction, the LLM-visible context has been replaced. We
  # don't know the new context size until the next assistant message
  # reports usage, so reset percent to nil — the footer renders `?`
  # for unknown.
  defp update_footer(footer, %CompactionEnd{result: {:ok, _}}), do: %{footer | context_percent: nil}

  defp update_footer(footer, _), do: footer

  # Mirrors `OctoPi.Agent.Loop.context_tokens_from_usage/1`: prefer
  # provider-supplied `total_tokens` when positive; otherwise sum
  # input + output + cache_read + cache_write so prompt-cache reads
  # still count toward the trigger.
  defp current_context_tokens(%{total_tokens: t}) when is_integer(t) and t > 0, do: t

  defp current_context_tokens(%{input: i, output: o, cache_read: cr, cache_write: cw})
       when is_integer(i) and is_integer(o) and is_integer(cr) and is_integer(cw), do: i + o + cr + cw

  defp current_context_tokens(_), do: nil

  # opi-4dx.13: streaming-tick coalescing.
  #
  # Block events update the top-level Transcript directly (latest-snapshot-
  # wins per block_id is automatic since Transcript.update only mutates
  # one slot). The streaming-tick deadline is stamped so :timeout fires a
  # single advance() per coalescing window rather than rendering once
  # per delta.
  @stream_tick_ms 33

  defp stamp_streaming_tick(%{streaming_tick_at: nil} = state) do
    %{state | streaming_tick_at: System.monotonic_time(:millisecond) + @stream_tick_ms}
  end

  defp stamp_streaming_tick(state), do: state

  defp drain_block_deltas(state) do
    receive do
      {:octo_pi_agent_event, %ev{}} = msg
      when ev in [Event.MessageBlockStart, Event.MessageBlockDelta, Event.MessageBlockEnd] ->
        drain_block_deltas(handle_event(state, msg))
    after
      0 -> state
    end
  end

  @doc """
  No-op shim for the legacy flush API. With `.13`, block events update
  the Transcript directly so there is nothing to flush — but the helper
  is kept callable so existing callers (and tests written against the
  pre-`.13` shape) compile and pass through unchanged.
  """
  @spec flush_pending_partial(t()) :: t()
  def flush_pending_partial(state), do: %{state | streaming_tick_at: nil}

  @doc false
  def streaming_tick_due?(%{streaming_tick_at: nil}, _now_ms), do: false
  def streaming_tick_due?(%{streaming_tick_at: at}, now_ms) when is_integer(at), do: now_ms >= at

  # --- block routing ---------------------------------------------

  defp append_block(state, block_id, kind, snapshot) do
    msg_id = state.current_msg_id || "turn-#{state.turn_seq}"
    key = block_key(msg_id, block_id)
    %{state | transcript: Transcript.append(state.transcript, key, block_struct(kind, snapshot))}
  end

  defp upsert_block(state, block_id, kind, snapshot) do
    msg_id = state.current_msg_id || "turn-#{state.turn_seq}"
    key = block_key(msg_id, block_id)

    transcript =
      if Transcript.has_entry?(state.transcript, key) do
        Transcript.update(state.transcript, key, snapshot)
      else
        Transcript.append(state.transcript, key, block_struct(kind, snapshot))
      end

    %{state | transcript: transcript}
  end

  defp finalize_block(state, block_id) do
    msg_id = state.current_msg_id || "turn-#{state.turn_seq}"
    key = block_key(msg_id, block_id)

    case Transcript.get_data(state.transcript, key) do
      nil -> state
      entry -> %{state | transcript: Transcript.finalize(state.transcript, key, entry.snapshot)}
    end
  end

  defp build_session_info(%{footer: f, transcript: t, session: session} = state) do
    user_count = Enum.count(t.data, fn {_, v} -> match?(%UserMessage{}, v) end)
    asst_count = Enum.count(t.data, fn {_, v} -> match?(%AssistantHeader{}, v) end)
    tool_count = Enum.count(t.data, fn {_, v} -> match?(%ToolExecution{}, v) end)
    total = map_size(t.data)

    lines =
      ["Session Info"]
      |> then(fn acc ->
        if state.footer.session_name, do: acc ++ ["Name: #{f.session_name}"], else: acc
      end)
      |> then(fn acc ->
        file = if session, do: inspect(session), else: "In-memory"
        acc ++ ["File: #{file}", "ID: #{if session, do: inspect(session), else: "(none)"}", ""]
      end)
      |> Kernel.++(["Messages"])
      |> Kernel.++([
        "User: #{user_count}",
        "Assistant: #{asst_count}",
        "Tool Calls: #{tool_count}",
        "Total: #{total}",
        ""
      ])
      |> Kernel.++(["Tokens"])
      |> Kernel.++(["Input: #{f.input_tokens}", "Output: #{f.output_tokens}"])
      |> then(fn acc ->
        acc = if f.cache_read > 0, do: acc ++ ["Cache Read: #{f.cache_read}"], else: acc
        acc = if f.cache_write > 0, do: acc ++ ["Cache Write: #{f.cache_write}"], else: acc
        total_tokens = f.input_tokens + f.output_tokens + f.cache_read + f.cache_write
        acc ++ ["Total: #{total_tokens}"]
      end)
      |> then(fn acc ->
        if f.cost > 0 do
          acc ++ ["", "Cost", "Total: $#{:erlang.float_to_binary(f.cost, decimals: 4)}"]
        else
          acc
        end
      end)

    Enum.join(lines, "\n")
  end

  defp last_assistant_text(%Transcript{order: order, data: data}) do
    order
    |> Enum.reverse()
    |> Enum.find_value(fn key ->
      case Map.get(data, key) do
        %TextBlock{snapshot: text} when byte_size(text) > 0 -> text
        _ -> nil
      end
    end)
  end

  defp copy_to_clipboard(text) do
    tmp = Path.join(System.tmp_dir!(), "pi_copy_#{:erlang.unique_integer([:positive])}.txt")
    File.write!(tmp, text)

    quoted = ~s("#{tmp}")

    cmd =
      case :os.type() do
        {:unix, :darwin} -> "pbcopy < #{quoted}"
        {:unix, _} -> "xclip -selection clipboard < #{quoted}"
        {:win32, _} -> "clip < #{quoted}"
      end

    {_output, exit_code} = System.shell(cmd)
    File.rm(tmp)

    if exit_code == 0, do: :ok, else: {:error, "exited #{exit_code}"}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp export_transcript_text(%Transcript{data: data}) do
    data
    |> Enum.flat_map(fn
      {_k, %UserMessage{text: text}} when is_binary(text) ->
        ["## User\n\n#{text}\n"]

      {_k, %TextBlock{snapshot: text}} when is_binary(text) ->
        ["## Assistant\n\n#{text}\n"]

      _ ->
        []
    end)
    |> Enum.join("\n")
  end

  defp user_messages_for_fork(%Transcript{data: data}) do
    data
    |> Enum.filter(fn {_k, v} -> match?(%UserMessage{}, v) end)
    |> Enum.map(fn {k, %UserMessage{text: text}} -> %{id: k, text: text || ""} end)
  end

  defp block_struct(:text, snapshot), do: %TextBlock{snapshot: snapshot}
  defp block_struct(:thinking, snapshot), do: %ThinkingBlock{snapshot: snapshot}
  defp block_struct(_, snapshot), do: %ThinkingBlock{snapshot: snapshot}

  # --- key minting -----------------------------------------------

  defp header_key(msg_id), do: "#{msg_id}:hdr"
  defp status_key(msg_id), do: "#{msg_id}:end"
  defp block_key(msg_id, idx), do: "#{msg_id}:#{idx}"
  defp tool_key(tool_call_id), do: "tool:#{tool_call_id}"
  defp bash_key(bash_id) when is_binary(bash_id), do: "bash:#{bash_id}"
  defp bash_key(bash_id), do: "bash:#{inspect(bash_id)}"
  defp user_key, do: "user:#{:erlang.unique_integer([:positive, :monotonic])}"
  defp compaction_key, do: "compaction:#{:erlang.unique_integer([:positive, :monotonic])}"

  # --- header lookup / mutation ----------------------------------

  defp maybe_update_header_tool_flag(transcript, msg_id, has_tool_calls?) do
    key = header_key(msg_id)

    case Transcript.get_data(transcript, key) do
      %AssistantHeader{} -> Transcript.update(transcript, key, has_tool_calls?)
      _ -> transcript
    end
  end

  defp extract_stop_reason(%{stop_reason: :stop}), do: nil
  defp extract_stop_reason(%{stop_reason: reason}) when is_atom(reason), do: reason
  defp extract_stop_reason(_), do: nil

  defp has_tool_calls?(%{content: content}) when is_list(content) do
    Enum.any?(content, &match?(%OctoPi.AI.ToolCall{}, &1))
  end

  defp has_tool_calls?(_), do: false

  defp extract_tool_result_text(%{content: content}) when is_list(content) do
    Enum.map_join(content, "\n", fn
      %{text: text} -> text
      other -> inspect(other)
    end)
  end

  defp extract_tool_result_text(%{text: text}), do: text
  defp extract_tool_result_text(result), do: inspect(result)

  # --- rendering helpers (pure) ---

  @doc """
  Build the current state into a flat list of lines ready for the
  Renderer. Components are concatenated in layout order — the
  Renderer handles terminal mechanics (scrolling, cursor, clearing).
  """
  @spec build_screen(t()) :: [binary()]
  def build_screen(%{input: input, width: width} = state) do
    input_vnode = %VDOM.VLines{lines: Components.Input.render(input, width)}
    {lines, _layout, _state} = build_screen(state, input_vnode)
    lines
  end

  @spec build_screen(t(), VDOM.t()) :: {[binary()], map(), t()}
  def build_screen(%{custom_widget: {_, component}, width: width, height: height} = state, _input_lines) do
    lines = component.render.(width)
    len = length(lines)
    lines = if len < height, do: List.duplicate("", height - len) ++ lines, else: lines
    {lines, %{footer_height: 0, dropdown_height: 0, notification_height: 0}, state}
  end

  def build_screen(
        %{transcript: transcript, footer: footer, banner: banner, loader: loader, width: width} = state,
        input_vnode
      ) do
    ctx = render_ctx(state)

    {transcript2, transcript_vnode} = Transcript.render(transcript, ctx)

    state = %{state | transcript: transcript2}

    pending_lines =
      Components.PendingMessages.render(
        %{
          pending_steering: state.pending_steering,
          pending_follow_up: state.pending_follow_up,
          keybindings: get_keybindings(state)
        },
        ctx
      )

    footer_vnode = footer_lines(Map.get(state.ui_overrides, :footer), footer, state.footer_data, ctx)

    dropdown_vnode = %VDOM.VLines{lines: Components.Input.render_dropdown(state.input, width)}
    notif_vnode = %VDOM.VLines{lines: render_notification(state.notification, width)}

    header_vnode =
      case Map.get(state.ui_overrides, :header) do
        render_fn when is_function(render_fn, 1) -> %VDOM.VLines{lines: render_fn.(width)}
        nil when is_nil(banner) -> %VDOM.VLines{lines: []}
        nil -> elem(Header.render(banner, ctx), 1)
      end

    resource_vnode =
      case state.loaded_resources do
        nil -> %VDOM.VLines{lines: []}
        resources -> elem(Components.Resources.render(resources, ctx), 1)
      end

    tree = %VDOM.VFlow{
      children: [
        header_vnode,
        resource_vnode,
        transcript_vnode,
        case loader do
          nil -> %VDOM.VLines{lines: []}
          %Components.Loader{} -> elem(Components.Loader.render(loader, ctx), 1)
        end,
        pending_lines,
        input_vnode,
        dropdown_vnode,
        notif_vnode,
        footer_vnode
      ]
    }

    {iodata, _cursor} =
      tree
      |> Paint.paint(LineBuf.new(), ctx)
      |> LineBuf.finalize()

    all = iodata |> IO.iodata_to_binary() |> String.split("\n")

    layout = %{
      footer_height: vnode_height(footer_vnode, ctx),
      dropdown_height: vnode_height(dropdown_vnode, ctx),
      notification_height: vnode_height(notif_vnode, ctx)
    }

    {all, layout, state}
  end

  defp build_custom_theme(%{theme: nil}), do: %{fg: fn _color, text -> text end}
  defp build_custom_theme(%{theme: theme}), do: %{fg: fn color, text -> Theme.fg(theme, color, text) end}

  defp default_working_message, do: "Thinking…"

  # opi-tze.5 / opi-tze.8: drain ALL queued steering and follow-up
  # messages from the agent and place them in the editor for free
  # editing. Mirrors upstream pi-mono
  # restoreQueuedMessagesToEditor/1 (interactive-mode.ts L3549-3568).
  #
  # Returns `{n, state}` where `n` is the total number of items
  # restored. When `abort?: true` is passed and the agent is
  # streaming, also calls Coder.abort/1 — used by Escape during a
  # run to cancel and reclaim the queued text in one gesture.
  @spec restore_queued_to_editor(t(), keyword()) :: {non_neg_integer(), t()}
  defp restore_queued_to_editor(%{session: nil} = state, _opts), do: {0, state}

  defp restore_queued_to_editor(state, opts) do
    abort? = Keyword.get(opts, :abort?, false)
    steering = Coder.drain_steering(state.session)
    follow_up = Coder.drain_follow_up(state.session)
    queued_texts = Enum.map(steering ++ follow_up, &message_text/1)
    n = length(queued_texts)

    if abort?, do: Coder.abort(state.session)

    if n == 0 do
      {0, state}
    else
      queued_text = Enum.join(queued_texts, "\n\n")
      current_text = state.input.value

      combined =
        [queued_text, current_text]
        |> Enum.reject(&(String.trim(&1) == ""))
        |> Enum.join("\n\n")

      input =
        state.input
        |> Components.Input.set_value(combined)
        |> Map.put(:cursor, String.length(combined))

      {n, %{state | input: input}}
    end
  end

  defp flush_compaction_queue(%{compaction_queue: []} = state), do: state

  defp flush_compaction_queue(%{compaction_queue: queue, session: session} = state) do
    # Use follow_up rather than prompt so the messages join the
    # follow_up_queue and get drained at the next idle/run boundary.
    # If we'd called Coder.prompt here, the second prompt onward
    # would race with the run started by the first and get
    # `{:error, :already_streaming}`. Mirrors upstream's
    # flushCompactionQueue using session.followUp.
    Enum.each(queue, fn text ->
      Coder.follow_up(session, text)
    end)

    %{state | compaction_queue: []}
  end

  defp compaction_label(:manual), do: "Compacting context… (Esc to cancel)"
  defp compaction_label(:pre_prompt), do: "Auto-compacting… (Esc to cancel)"
  defp compaction_label(:mid_run), do: "Auto-compacting… (Esc to cancel)"
  defp compaction_label(:overflow), do: "Context overflow detected, auto-compacting… (Esc to cancel)"
  defp compaction_label(_), do: "Compacting context… (Esc to cancel)"

  defp render_ctx(state) do
    %RenderContext{
      theme: state.theme,
      width: state.width,
      padding_x: 1,
      hide_thinking: not state.thinking_visible,
      hidden_thinking_label: "Thinking..."
    }
  end

  defp vnode_height(vnode, ctx), do: Paint.paint(vnode, LineBuf.new(), ctx).line_count

  defp render_notification(nil, _width), do: []

  defp render_notification(text, width) do
    text
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      [%TruncatedText{text: Theme.dim(line)}] |> Container.new() |> Container.render(width)
    end)
  end

  # Extract a plain string from a queued message struct. Post-
  # opi-5ka.3 every %User{} reaching the TUI's pending-messages
  # indicator has list-shape content (a single %Text{} for items
  # built from a string, or %Text{}/%Image{} blocks for items
  # reconstructed from session state).
  defp message_text(%{content: c}) when is_list(c) do
    Enum.map_join(c, "\n", fn
      %{__struct__: Text, text: t} -> t
      %{text: t} when is_binary(t) -> t
      _ -> ""
    end)
  end

  defp message_text(other), do: inspect(other)

  defp next_thinking_level(:off), do: :low
  defp next_thinking_level(:low), do: :medium
  defp next_thinking_level(:medium), do: :high
  defp next_thinking_level(:high), do: :off
  defp next_thinking_level(_), do: :low

  defp thinking_level_label(:off), do: "thinking off"
  defp thinking_level_label(level), do: to_string(level)

  defp dispatch_key_to_focused(state, key) do
    case state.focused_component do
      :input -> handle_input_key(state, key)
      {:dialog, dialog_key} -> dispatch_dialog_key(state, dialog_key, key)
      nil -> state
    end
  end

  defp dispatch_dialog_key(state, :model_selector, key), do: handle_model_selector_key(state, key)
  defp dispatch_dialog_key(state, :login, key), do: handle_login_dialog_key(state, key)
  defp dispatch_dialog_key(state, :settings, key), do: handle_settings_selector_key(state, key)
  defp dispatch_dialog_key(state, :settings_list, key), do: handle_settings_list_key(state, key)
  defp dispatch_dialog_key(state, :session_selector, key), do: handle_session_selector_key(state, key)
  defp dispatch_dialog_key(state, :user_message_selector, key), do: handle_user_message_selector_key(state, key)
  defp dispatch_dialog_key(state, :tree_selector, key), do: handle_tree_selector_key(state, key)
  defp dispatch_dialog_key(state, :summarize_prompt, key), do: handle_summarize_prompt_key(state, key)
  defp dispatch_dialog_key(state, :select_list, key), do: handle_select_list_key(state, key)
  defp dispatch_dialog_key(state, _unknown, _key), do: state

  defp handle_input_key(state, key) do
    kb = get_keybindings(state)

    case find_app_action(kb, key) do
      nil -> handle_event_after_app(state, key)
      action -> dispatch_app_action(action, state, key)
    end
  end

  defp handle_model_selector_key(%{model_selector: ms} = state, key) do
    case ModelSelector.handle_key(ms, key) do
      {_new_ms, [:cancel]} ->
        unfocus(%{state | model_selector: nil})

      {_new_ms, [{:select_model, model}]} ->
        if state.session, do: Coder.set_model(state.session, model)

        unfocus(%{
          state
          | model_selector: nil,
            model: model,
            footer: %{state.footer | model_id: model.id, provider: model.provider}
        })

      result ->
        apply_component_result(state, :model_selector, result)
    end
  end

  # Handle printable characters for login dialog (e.g., typing API key)
  defp handle_login_dialog_key(%{login_dialog: ld} = state, %Key{key: cp, modifiers: []}) when is_integer(cp) do
    new_ld = LoginDialog.handle_char(ld, <<cp::utf8>>)
    %{state | login_dialog: new_ld}
  end

  defp handle_login_dialog_key(%{login_dialog: ld} = state, key) do
    case LoginDialog.handle_key(ld, key) do
      {_new_ld, [:cancel]} -> unfocus(%{state | login_dialog: nil})
      {_new_ld, [{:api_key_entered, api_key}]} -> apply_api_key(unfocus(%{state | login_dialog: nil}), api_key)
      result -> apply_component_result(state, :login_dialog, result)
    end
  end

  defp handle_settings_selector_key(%{settings_selector: ss} = state, key) do
    case SettingsSelector.handle_key(ss, key) do
      {_new_ss, [:cancel]} ->
        unfocus(%{state | settings_selector: nil})

      {new_ss, [{:setting_changed, setting_key, value}]} ->
        apply_setting(unfocus(%{state | settings_selector: new_ss}), setting_key, value)

      result ->
        apply_component_result(state, :settings_selector, result)
    end
  end

  defp handle_settings_list_key(%{settings_list: sl} = state, key) do
    case SettingsList.handle_key(sl, key) do
      {_new_sl, [:cancel]} ->
        unfocus(%{state | settings_list: nil})

      {new_sl, [{:setting_changed, item_id, value}]} ->
        apply_setting(unfocus(%{state | settings_list: new_sl}), item_id, value)

      result ->
        apply_component_result(state, :settings_list, result)
    end
  end

  defp handle_session_selector_key(%{session_selector: ss} = state, key) do
    case SessionSelector.handle_key(ss, key) do
      {_new_ss, [:cancel]} -> unfocus(%{state | session_selector: nil})
      {_new_ss, [{:resume_session, session}]} -> resume_session(unfocus(%{state | session_selector: nil}), session)
      {new_ss, [{:delete_session, session}]} -> delete_session(%{state | session_selector: new_ss}, session)
      result -> apply_component_result(state, :session_selector, result)
    end
  end

  defp handle_user_message_selector_key(%{user_message_selector: ums} = state, key) do
    case UserMessageSelector.handle_key(ums, key) do
      {_new_ums, [:cancel]} -> unfocus(%{state | user_message_selector: nil})
      {_new_ums, [{:fork_at, msg}]} -> fork_from(unfocus(%{state | user_message_selector: nil}), msg)
      result -> apply_component_result(state, :user_message_selector, result)
    end
  end

  defp handle_tree_selector_key(%{tree_selector: ts} = state, key) do
    case TreeSelector.handle_key(ts, key) do
      {_new_ts, [:cancel]} ->
        unfocus(%{state | tree_selector: nil})

      {_new_ts, [{:select, entry_id}]} ->
        sp = SummarizePrompt.new()
        state = %{state | tree_selector: nil, summarize_prompt: sp, dialog: {:tree_navigate, entry_id}}
        focus(state, {:dialog, :summarize_prompt})

      result ->
        apply_component_result(state, :tree_selector, result)
    end
  end

  defp handle_summarize_prompt_key(%{summarize_prompt: sp, dialog: {:tree_navigate, entry_id}} = state, key) do
    case SummarizePrompt.handle_key(sp, key) do
      {_sp, [:cancel]} ->
        unfocus(%{state | summarize_prompt: nil, dialog: nil})

      {_sp, [{:result, choice}]} ->
        state = unfocus(%{state | summarize_prompt: nil, dialog: nil})
        do_tree_navigate(state, entry_id, choice)

      {_sp, [:awaiting_custom_instructions]} ->
        unfocus(%{state | summarize_prompt: nil, editor_pending: true})

      result ->
        apply_component_result(state, :summarize_prompt, result)
    end
  end

  defp handle_summarize_prompt_key(%{summarize_prompt: sp} = state, key) do
    case SummarizePrompt.handle_key(sp, key) do
      {_sp, [:cancel]} -> unfocus(%{state | summarize_prompt: nil})
      {_sp, [{:result, _choice}]} -> unfocus(%{state | summarize_prompt: nil})
      {_sp, [:awaiting_custom_instructions]} -> unfocus(%{state | summarize_prompt: nil, editor_pending: true})
      result -> apply_component_result(state, :summarize_prompt, result)
    end
  end

  defp do_tree_navigate(%{session: session, model: model} = state, entry_id, choice) when not is_nil(session) do
    opts = [target_id: entry_id, user_wants_summary: choice, model: model]

    case Coder.navigate_tree(session, opts) do
      {:ok, _summary} -> %{state | notification: "Navigated to selected point", current_msg_id: nil}
      {:error, :no_model} -> %{state | notification: "Navigation failed: no model"}
      {:error, :not_found} -> %{state | notification: "Navigation failed: entry not found"}
      {:error, reason} -> %{state | notification: "Navigation failed: #{inspect(reason)}"}
      {:cancel, _} -> state
    end
  end

  defp do_tree_navigate(state, _entry_id, _choice), do: state

  defp handle_select_list_key(%{select_list: sl} = state, key) do
    case SelectList.handle_key(sl, key) do
      {_new_sl, [:cancel]} -> resolve_select_list(state, nil)
      {_new_sl, [{:select, value}]} -> resolve_select_list(state, value)
      result -> apply_component_result(state, :select_list, result)
    end
  end

  defp apply_api_key(%{model: %{provider: provider}} = state, api_key) when is_binary(api_key) do
    # Save API key to ~/.octo_pi/auth.json for the current provider
    save_auth_key(provider, api_key)
    %{state | notification: "API key saved for #{provider}"}
  end

  defp apply_api_key(state, api_key) when is_binary(api_key) do
    # Fallback: save under a default provider key
    save_auth_key(:default, api_key)
    %{state | notification: "API key saved (restart to use)"}
  end

  defp read_auth_providers do
    auth_file = Path.expand("~/.octo_pi/auth.json")

    case File.read(auth_file) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, map} when is_map(map) -> map |> Map.keys() |> Enum.sort()
          _ -> []
        end

      _ ->
        []
    end
  end

  defp delete_auth_provider(provider) do
    auth_file = Path.expand("~/.octo_pi/auth.json")

    existing =
      case File.read(auth_file) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    updated = Map.delete(existing, provider)
    File.mkdir_p!(Path.dirname(auth_file))
    File.write!(auth_file, Jason.encode!(updated, pretty: true))
  end

  defp save_auth_key(provider, api_key) do
    auth_file = Path.expand("~/.octo_pi/auth.json")

    # Load existing auth.json or start with empty map
    existing =
      case File.read(auth_file) do
        {:ok, body} ->
          case Jason.decode(body) do
            {:ok, map} when is_map(map) -> map
            _ -> %{}
          end

        _ ->
          %{}
      end

    # Update with new key (under provider name or :default)
    updated = Map.put(existing, to_string(provider), %{"literal" => api_key})

    # Ensure directory exists
    File.mkdir_p!(Path.dirname(auth_file))

    # Write updated auth.json
    :ok = File.write(auth_file, Jason.encode!(updated, pretty: true))
  end

  defp apply_setting(state, _key, _value), do: state

  defp resume_session(state, _session), do: state

  defp delete_session(state, _session), do: state

  defp fork_from(state, _msg), do: %{state | notification: "Forked to new session"}

  defp resolve_select_list(%{dialog: {:select, :logout, _options, _opts}} = state, nil) do
    unfocus(%{state | select_list: nil, dialog: nil})
  end

  defp resolve_select_list(%{dialog: {:select, :logout, _options, _opts}} = state, provider) when is_binary(provider) do
    delete_auth_provider(provider)
    unfocus(%{state | select_list: nil, dialog: nil, notification: "Logged out of #{provider}"})
  end

  defp resolve_select_list(%{dialog: {:select, from, _options, _opts}} = state, value) when not is_nil(from) do
    GenServer.reply(from, value)
    unfocus(%{state | select_list: nil, dialog: nil})
  end

  defp resolve_select_list(state, _value) do
    unfocus(%{state | select_list: nil, dialog: nil})
  end

  defp list_recent_sessions(%{footer: %Footer{cwd: cwd}}) do
    session_dir = SessionStore.session_dir(cwd)

    case File.ls(session_dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(&session_file_info(session_dir, &1))
        |> Enum.sort_by(& &1.updated_at, {:desc, DateTime})

      _ ->
        []
    end
  end

  defp session_file_info(dir, name) do
    id = String.replace_suffix(name, ".jsonl", "")
    path = Path.join(dir, name)

    stat = File.stat!(path, time: :posix)
    updated_at = DateTime.from_unix!(stat.mtime)
    created_at = DateTime.from_unix!(stat.ctime)
    message_count = count_jsonl_lines(path)

    %{id: id, name: id, path: path, message_count: message_count, updated_at: updated_at, created_at: created_at}
  end

  defp count_jsonl_lines(path) do
    path
    |> File.stream!()
    |> Enum.count()
  rescue
    _ -> 0
  end

  defp open_session_selector(state) do
    sessions = list_recent_sessions(state)
    current_id = state.session && inspect(state.session)
    ss = SessionSelector.new(sessions, state.theme, current: current_id)
    focus(%{state | session_selector: ss}, {:dialog, :session_selector})
  end

  defp select_list_item(%SelectList.Item{} = item), do: item

  defp select_list_item(%{value: v, label: l} = m),
    do: %SelectList.Item{value: v, label: l, description: Map.get(m, :description)}

  defp select_list_item(s) when is_binary(s), do: s

  defp focus(state, target), do: %{state | focused_component: target}
  defp unfocus(state), do: %{state | focused_component: :input}

  defp apply_component_result(state, field, {new_component, events}) do
    Enum.reduce(events, Map.put(state, field, new_component), &handle_component_event(&2, &1))
  end

  defp apply_component_result(state, field, new_component) do
    Map.put(state, field, new_component)
  end

  defp handle_component_event(state, {:cancel}), do: unfocus(state)
  defp handle_component_event(state, _event), do: state

  defp cycle_model(models, current, dir) do
    idx = Enum.find_index(models, &(&1 == current)) || -1
    len = length(models)

    new_idx =
      case dir do
        :next -> rem(idx + 1, len)
        :prev -> rem(idx - 1 + len, len)
      end

    Enum.at(models, new_idx)
  end

  defp footer_lines(render_fn, footer, footer_data_pid, %RenderContext{width: width}) when is_function(render_fn, 2) do
    lines = render_fn.(width, build_footer_context(footer, footer_data_pid))
    %VDOM.VLines{lines: lines}
  end

  defp footer_lines(nil, footer, _footer_data_pid, %RenderContext{} = ctx), do: elem(Footer.render(footer, ctx), 1)

  defp build_footer_context(footer, footer_data_pid) do
    %{
      get_git_branch: fn -> branch_from(footer_data_pid) end,
      get_extension_statuses: fn -> footer.extension_statuses end,
      on_branch_change: fn _cb -> fn -> :ok end end
    }
  end

  defp branch_from(nil), do: nil
  defp branch_from(pid), do: FooterData.get_git_branch(pid)
end
