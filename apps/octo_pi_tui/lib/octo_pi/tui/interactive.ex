defmodule OctoPi.TUI.Interactive do
  @moduledoc """
  Main loop for `mix pi` interactive mode.

  Composes the Phase 4 pieces end-to-end: `Terminal` owns the tty,
  assembles cooked stdin sequences, and parses them into key events;
  the `Input` component accumulates the prompt, and the `Renderer`
  paints the transcript + input to the screen. Agent events from
  `OctoPi.Agent.Session` drive the transcript updates.

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
  alias OctoPi.AI.Model
  alias OctoPi.Coder
  alias OctoPi.Coder.Session, as: CoderSession
  alias OctoPi.Coder.Session.CompactionSummaryMessage, as: CoderCSM
  alias OctoPi.Coder.Session.Messages, as: SessionMessages
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event, as: ExtEvent
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.UIHost
  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.SlashCommandProvider
  alias OctoPi.TUI.Components
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.BashExecution
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Components.ModelSelector
  alias OctoPi.TUI.Components.CompactionSummaryMessage, as: TUICSM
  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Components.UserMessage
  alias OctoPi.TUI.AgentTelemetryLogger
  alias OctoPi.TUI.EventLogger
  alias OctoPi.TUI.FooterData
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.Overlay
  alias OctoPi.TUI.Paste
  alias OctoPi.TUI.Renderer
  alias OctoPi.TUI.Safe
  alias OctoPi.TUI.Terminal
  alias OctoPi.TUI.Terminal.RawMode
  alias OctoPi.TUI.Terminal.Resize
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Tracer
  alias OctoPi.TUI.WrapAnsi

  @type resource_data :: %{
          context_files: [%{path: String.t()}],
          skills: [%{name: String.t()}],
          prompt_templates: [%{name: String.t()}]
        }

  @type t :: %__MODULE__{
          session: pid() | nil,
          sup: pid() | nil,
          renderer: pid() | nil,
          terminal: pid() | nil,
          raw_mode_fn: (atom() -> :ok) | nil,
          skip_raw_mode: boolean(),
          send_sigtstp_fn: (-> :ok),
          keybindings: Keybindings.t() | nil,
          input: Components.Input.t(),
          transcript: [struct()],
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
          dequeue_overlay: %{items: list(), selected: non_neg_integer()} | nil,
          tools_expanded: boolean(),
          thinking_visible: boolean(),
          loader: Components.Loader.t() | nil,
          working_message: String.t() | nil,
          notification: String.t() | nil,
          banner: Components.WelcomeBanner.t() | nil,
          loaded_resources: resource_data() | nil,
          expand_prompt_fn: (String.t() -> String.t()) | nil,
          ui_overrides: map(),
          dialog: tuple() | nil,
          custom_widget: {GenServer.from(), map()} | nil,
          extension_shortcuts: [{(Key.t() -> boolean()), (t() -> t())}],
          extensions: [Extension.t()]
        }

  # credo:disable-for-next-line Credo.Check.Warning.StructFieldAmount
  defstruct session: nil,
            sup: nil,
            renderer: nil,
            terminal: nil,
            raw_mode_fn: nil,
            skip_raw_mode: false,
            send_sigtstp_fn: &__MODULE__.default_send_sigtstp/0,
            keybindings: nil,
            input: %Components.Input{},
            transcript: [],
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
            dequeue_overlay: nil,
            tools_expanded: false,
            thinking_visible: true,
            loader: nil,
            working_message: nil,
            notification: nil,
            ui_overrides: %{},
            dialog: nil,
            custom_widget: nil,
            extension_shortcuts: [],
            extensions: []

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
    {%{state | tools_expanded: val}, :ok}
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
    {%{state | dialog: {:select, nil, options, opts}}, :pending}
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
    if state.session, do: CoderSession.add_tool(state.session, spec)
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

  @doc """
  Entry point for the CLI. Starts the Interactive GenServer, then
  blocks until it exits.

  Options:

    * `:model`    — `%OctoPi.AI.Model{}` (required for real runs)
    * `:tools`    — list of `%OctoPi.Agent.Tool{}` (default `[]`)
    * `:transport`, `:system_prompt` — forwarded to
      `OctoPi.Agent.start_session/1`
    * `:dimensions` — `{w, h}` override for tests
    * `:write_fn`  — 1-arg fn that receives rendered bytes;
      default `&IO.write/1`. Tests use this to capture output.
    * `:skip_raw_mode`, `:skip_sigwinch`, `:auto_start_reader`,
      `:raw_mode_fn` — Terminal test overrides, passed through.
    * `:terminal_name` — name under which to register the
      Terminal GenServer. Pass `nil` to leave it unregistered
      (useful when multiple Interactive runs share a VM, e.g.
      tests).
    * `:name` — name under which to register *this* Interactive
      GenServer. Tests use it to address Interactive directly
      (e.g. `send(name, {:hid_event, %Key{...}})`). Default
      unregistered.
  """
  @spec run(keyword()) :: :ok
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

    if Keyword.get(opts, :debug_events, false) do
      path = Path.join(cwd, "debug_events.log")
      EventLogger.attach(path)
    end

    case Keyword.get(opts, :trace) do
      nil ->
        :ok

      trace_path ->
        fd = Tracer.attach(trace_path)
        Process.put(:tracer_fd, fd)
    end

    case Keyword.get(opts, :telemetry) do
      nil ->
        :ok

      telemetry_path ->
        fd = AgentTelemetryLogger.attach(telemetry_path)
        Process.put(:telemetry_fd, fd)
    end

    extensions = load_extensions(opts, cwd)
    session = start_sessions(opts, extensions)

    terminal_opts = build_terminal_opts(opts, write_fn)

    children = [
      %{id: Terminal, start: {Terminal, :start_link, [terminal_opts]}},
      %{id: Renderer, start: {Renderer, :start_link, [[width: w, height: h, csi_2026?: true]]}},
      %{id: FooterData, start: {FooterData, :start_link, [[cwd: cwd]]}}
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_all, max_restarts: 0)

    terminal = child_pid(sup, Terminal)
    renderer = child_pid(sup, Renderer)
    footer_data = child_pid(sup, FooterData)

    :ok = Terminal.open(terminal)
    CoderSession.subscribe(session, self(), :async)

    theme = Theme.load_builtin(:dark, Theme.detect_color_mode())

    footer = %Footer{
      cwd: cwd,
      model_id: model.id,
      provider: model.provider,
      context_window: model.context_window,
      git_branch: FooterData.get_git_branch(footer_data)
    }

    loaded_resources = build_loaded_resources(opts)
    keybindings = load_keybindings(Keyword.take(opts, [:keybindings_path]))

    state = %__MODULE__{
      session: session,
      sup: sup,
      renderer: renderer,
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
      banner: Components.WelcomeBanner.new(theme, model: model.id),
      footer: footer,
      footer_data: footer_data,
      loaded_resources: loaded_resources,
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
    state = render_frame(state)
    {:noreply, state, loader_timeout(state)}
  end

  @impl GenServer
  def handle_info({:hid_event, %Resize{width: w, height: h} = event}, state) do
    Renderer.resize(state.renderer, w, h)

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

  def handle_info(:timeout, state) do
    state
    |> handle_event(:loader_tick)
    |> advance()
  end

  def handle_info({:EXIT, pid, _reason}, %{sup: sup} = state) when pid == sup do
    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state, loader_timeout(state)}
  end

  def handle_info(_msg, state) do
    {:noreply, state, loader_timeout(state)}
  end

  @impl GenServer
  def handle_call({:ui_request, {:custom, factory, _kw}}, from, state) do
    interactive_pid = self()
    tui = %{request_render: fn -> send(interactive_pid, :force_render) end}
    theme = build_custom_theme(state)
    done = fn result -> send(interactive_pid, {:custom_done, from, result}) end
    component = factory.(tui, theme, done)
    new_state = render_frame(%{state | custom_widget: {from, component}})
    {:noreply, new_state, loader_timeout(new_state)}
  end

  def handle_call({:ui_request, msg}, from, state) do
    {new_state, reply} = handle_ui_request(state, msg)

    case reply do
      :pending ->
        new_state = put_dialog_from(new_state, from)
        new_state = render_frame(new_state)
        {:noreply, new_state, loader_timeout(new_state)}

      val ->
        new_state = render_frame(new_state)
        {:reply, val, new_state, loader_timeout(new_state)}
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
    with pid when is_pid(pid) <- state.renderer,
         true <- Process.alive?(pid),
         bytes when bytes != "" <- Renderer.exit_bytes(pid),
         term when is_pid(term) <- state.terminal,
         true <- Process.alive?(term) do
      Terminal.write(term, bytes)
    end

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

    if fd = Process.get(:tracer_fd) do
      Tracer.detach(fd)
      Process.delete(:tracer_fd)
    end

    if fd = Process.get(:telemetry_fd) do
      AgentTelemetryLogger.detach(fd)
      Process.delete(:telemetry_fd)
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

  defp loader_timeout(%{loader: %Components.Loader{}}), do: @loader_interval_ms
  defp loader_timeout(_), do: :infinity

  defp put_dialog_from(%{dialog: {type, nil, a, b}} = state, from), do: %{state | dialog: {type, from, a, b}}

  defp put_dialog_from(state, _from), do: state

  defp advance(%{exit: true} = state), do: {:stop, :normal, state}

  defp advance(state) do
    state = maybe_suspend(state)
    state = maybe_launch_editor(state)
    state = render_frame(state)
    {:noreply, state, loader_timeout(state)}
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
    sm = %SessionManager{cwd: cwd, session_id: session_id}

    {:ok, coder_pid} =
      CoderSession.start_link(
        extensions: extensions,
        session_manager: sm,
        store_pid: store_pid,
        model_provider: fn -> model end
      )

    agent_opts =
      put_if_present(
        [model: model, tools: tools, system_prompt: system_prompt],
        :transport,
        opts[:transport]
      )

    {:ok, agent_pid} = OctoPi.Agent.start_session(agent_opts)
    :ok = CoderSession.set_agent_pid(coder_pid, agent_pid)
    coder_pid
  end

  defp resume_or_new(cwd, model, tools, system_prompt, extensions, opts) do
    session_dir = SessionStore.session_dir(cwd)

    case SessionManager.find_recent(session_dir) do
      nil ->
        new_session(cwd, model, tools, system_prompt, extensions, opts)

      path ->
        {:ok, sm} = SessionManager.load(path)
        {:ok, store_pid} = SessionStore.start_link(id: sm.session_id, path: path)

        {:ok, coder_pid} =
          CoderSession.start_link(
            extensions: extensions,
            session_manager: sm,
            store_pid: store_pid,
            model_provider: fn -> model end
          )

        messages_provider = fn _session ->
          ctx = CoderSession.build_session_context(coder_pid)
          SessionMessages.to_llm(ctx.messages)
        end

        agent_opts =
          put_if_present(
            [model: model, tools: tools, system_prompt: system_prompt,
             messages_provider: messages_provider],
            :transport,
            opts[:transport]
          )

        {:ok, agent_pid} = OctoPi.Agent.start_session(agent_opts)
        :ok = CoderSession.set_agent_pid(coder_pid, agent_pid)
        coder_pid
    end
  end

  defp new_session_id do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end

  defp put_if_present(kw, _k, nil), do: kw
  defp put_if_present(kw, k, v), do: Keyword.put(kw, k, v)

  @doc false
  @spec build_autocomplete_provider(map() | nil, [Extension.t()]) :: SlashCommandProvider.t()
  def build_autocomplete_provider(loaded_resources, extensions \\ []) do
    template_commands =
      case loaded_resources do
        %{prompt_templates: templates} ->
          Enum.map(templates, fn t ->
            %Autocomplete.SlashCommand{name: t.name, description: "Prompt template"}
          end)

        _ ->
          []
      end

    extension_commands =
      Enum.map(Dispatcher.get_registered_commands(extensions), fn entry ->
        %Autocomplete.SlashCommand{
          name: entry.invocation_name,
          description: entry.cmd.description
        }
      end)

    SlashCommandProvider.new(Autocomplete.builtin_commands() ++ template_commands ++ extension_commands)
  end

  defp build_loaded_resources(opts) do
    case Keyword.get(opts, :resource_loader) do
      nil ->
        nil

      loader ->
        %{
          context_files: Enum.map(loader.context_files, &%{path: &1.path}),
          skills: Enum.map(loader.skills, &%{name: &1.name}),
          prompt_templates: Enum.map(loader.prompt_templates, &%{name: &1.name})
        }
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
      CoderSession.add_tool(coder_session, tool)
    end

    :ok
  end

  defp fire_session_start([], _cwd, _interactive_pid), do: :ok

  defp fire_session_start(extensions, cwd, interactive_pid) do
    ctx = Context.new(%{cwd: cwd, has_ui?: true, ui: build_ui_context(interactive_pid)})
    Dispatcher.emit(extensions, ExtEvent.new(:session_start, %{reason: :startup}), ctx)
  end

  defp fire_extension_event([], _event_type, _state), do: :ok

  defp fire_extension_event(extensions, event_type, state) do
    interactive_pid = self()
    cwd = state.footer.cwd

    Task.start(fn ->
      ctx = Context.new(%{cwd: cwd, has_ui?: true, ui: build_ui_context(interactive_pid)})
      Dispatcher.emit(extensions, ExtEvent.new(event_type), ctx)
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
  defp maybe_suspend(%{suspend_pending: true} = state) do
    Terminal.close(state.terminal)
    state.send_sigtstp_fn.()
    Terminal.open(state.terminal)
    %{state | suspend_pending: false}
  end

  defp maybe_suspend(state), do: state

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

  defp render_frame(state) do
    input = Components.Input.update_scroll(state.input, state.width)
    state = %{state | input: input}
    input_lines = Components.Input.render(input, state.width)
    lines = render(state, input_lines)
    lines = maybe_composite_model_selector(state, lines)
    lines = maybe_composite_dequeue_overlay(state, lines)

    case Process.get(:debug_render_log) do
      nil -> :ok
      fd -> log_overwide(fd, lines, state.width)
    end

    post_input_h = post_input_height(state)
    cursor_seq = cursor_position(state, input_lines, lines, post_input_h)
    {:ok, bytes} = Renderer.render(state.renderer, lines, cursor_seq)

    if bytes != "", do: Terminal.write(state.terminal, bytes)
    state
  end

  defp maybe_composite_model_selector(%{model_selector: nil}, lines), do: lines

  defp maybe_composite_model_selector(%{model_selector: ms, width: w, height: h}, lines) do
    ov_w = min(60, w)
    ov_lines = ModelSelector.render(ms, ov_w)
    ov = %Overlay{lines: ov_lines, anchor: :center, width: ov_w, margin: 2}
    Overlay.composite(lines, [ov], w, h)
  end

  defp maybe_composite_dequeue_overlay(%{dequeue_overlay: nil}, lines), do: lines

  defp maybe_composite_dequeue_overlay(%{dequeue_overlay: ov, width: w, height: h, theme: theme}, lines) do
    ov_w = min(70, w)
    ov_lines = render_dequeue_items(ov.items, ov.selected, ov_w, theme)
    overlay = %Overlay{lines: ov_lines, anchor: :center, width: ov_w, margin: 2}
    Overlay.composite(lines, [overlay], w, h)
  end

  defp render_dequeue_items(items, selected, _width, theme) do
    Enum.with_index(items, fn {type, msg}, idx ->
      prefix = if idx == selected, do: "→ ", else: "  "
      type_tag = dim("[#{type}]")
      text = if is_map(msg) and Map.has_key?(msg, :content), do: to_string(msg.content), else: inspect(msg)
      label = "#{prefix}#{type_tag} #{text}"
      if idx == selected and theme, do: Theme.fg(theme, :accent, label), else: label
    end)
  end

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

  defp post_input_height(%__MODULE__{input: input, width: width, notification: notification}) do
    length(Components.Input.render_dropdown(input, width)) +
      length(render_notification(notification, width))
  end

  defp cursor_position(%__MODULE__{custom_widget: cw}, _input_lines, _lines, _post_input_h) when not is_nil(cw),
    do: "\e[?25l"

  defp cursor_position(
         %__MODULE__{
           input: input,
           width: width,
           height: height,
           footer: footer,
           ui_overrides: ui_overrides,
           footer_data: footer_data_pid
         },
         input_lines,
         lines,
         post_input_h
       ) do
    {crow, ccol} = Components.Input.cursor_rc(input, width)
    footer_height = length(footer_lines(Map.get(ui_overrides, :footer), footer, footer_data_pid, width))
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

  def handle_event(%{model_selector: ms} = state, %Key{} = key) when not is_nil(ms) do
    case ModelSelector.handle_key(ms, key) do
      {_new_ms, [:cancel]} ->
        %{state | model_selector: nil}

      {_new_ms, [{:select_model, model}]} ->
        if state.session, do: CoderSession.set_model(state.session, model)

        %{
          state
          | model_selector: nil,
            model: model,
            footer: %{state.footer | model_id: model.id, provider: model.provider}
        }

      new_ms ->
        %{state | model_selector: new_ms}
    end
  end

  def handle_event(%{dequeue_overlay: ov} = state, %Key{} = key) when not is_nil(ov) do
    handle_dequeue_key(state, ov, key)
  end

  def handle_event(state, %Key{} = key) do
    kb = get_keybindings(state)

    case find_app_action(kb, key) do
      nil -> handle_event_after_app(state, key)
      action -> dispatch_app_action(action, state, key)
    end
  end

  def handle_event(%{input: input} = state, %Paste{content: content}) when is_binary(content),
    do: %{state | input: Components.Input.paste(input, content)}

  def handle_event(state, {:octo_pi_agent_event, %Event.AgentStart{}}) do
    fire_extension_event(state.extensions, :agent_start, state)
    message = state.working_message || default_working_message()
    %{state | loader: Components.Loader.new(message: message)}
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

  def handle_event(state, {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, data}}}) do
    theme = state.theme || Theme.load_builtin(:dark, Theme.detect_color_mode())
    coder_msg = CoderCSM.new(data.summary, Map.get(data, :tokens_before, 0), DateTime.utc_now() |> DateTime.to_iso8601())
    csm = TUICSM.new(coder_msg, theme)
    %{state | transcript: [csm]}
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.CompactionEnd{}}), do: state

  def handle_event(state, {:octo_pi_agent_event, event}) do
    %{
      state
      | transcript: update_transcript(state.transcript, event, state.theme),
        footer: update_footer(state.footer, event)
    }
  end

  def handle_event(state, %Resize{width: w, height: h}),
    do: %{state | width: w, height: h, input: %{state.input | width: w, height: h}}

  def handle_event(%{loader: %Components.Loader{} = loader} = state, :loader_tick),
    do: %{state | loader: Components.Loader.advance_frame(loader)}

  def handle_event(state, {:bash_done, id, output, exit_code}) do
    transcript =
      Enum.map(state.transcript, fn
        %BashExecution{id: ^id} = be ->
          be |> BashExecution.append_output(output) |> BashExecution.set_complete(exit_code)

        other ->
          other
      end)

    %{state | transcript: transcript}
  end

  def handle_event(state, _), do: state

  defp handle_event_after_app(%{extension_shortcuts: [_ | _] = shortcuts} = state, key) do
    case try_extension_shortcut(shortcuts, key, state) do
      {:consumed, new_state} -> new_state
      :pass -> handle_event_key(state, key)
    end
  end

  defp handle_event_after_app(state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.interrupt", %{loader: %Components.Loader{}, input: %{value: v}} = state, _key)
       when v != "" do
    %{state | input: %{state.input | value: "", cursor: 0}}
  end

  defp dispatch_app_action("app.interrupt", %{loader: %Components.Loader{}} = state, _key) do
    if state.session, do: CoderSession.abort(state.session)
    state
  end

  defp dispatch_app_action("app.interrupt", state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.clear", %{input: %{value: v}} = state, _key) when v != "",
    do: %{state | input: %{state.input | value: "", cursor: 0}}

  defp dispatch_app_action("app.clear", %{loader: %Components.Loader{}} = state, _key) do
    if state.session, do: CoderSession.abort(state.session)
    state
  end

  defp dispatch_app_action("app.clear", state, _key), do: state

  defp dispatch_app_action("app.exit", %{input: %{value: ""}} = state, _key), do: %{state | exit: true}
  defp dispatch_app_action("app.exit", state, key), do: handle_event_key(state, key)

  defp dispatch_app_action("app.suspend", state, _key), do: %{state | suspend_pending: true}

  defp dispatch_app_action("app.thinking.toggle", state, _key), do: %{state | thinking_visible: !state.thinking_visible}

  defp dispatch_app_action("app.thinking.cycle", state, _key) do
    new_level = next_thinking_level(state.thinking_level)
    if state.session, do: CoderSession.set_thinking_level(state.session, new_level)
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
        %Components.WelcomeBanner{} = b -> %{b | expanded: expanded}
        other -> other
      end

    %{state | tools_expanded: expanded, banner: banner}
  end

  defp dispatch_app_action("app.editor.external", state, _key), do: %{state | editor_pending: true}

  defp dispatch_app_action("app.message.dequeue", %{session: nil} = state, _key), do: state

  defp dispatch_app_action("app.message.dequeue", state, _key) do
    steering = CoderSession.drain_steering(state.session)
    follow_up = CoderSession.drain_follow_up(state.session)
    items = Enum.map(steering, &{:steering, &1}) ++ Enum.map(follow_up, &{:follow_up, &1})

    if items == [],
      do: %{state | notification: "No queued messages"},
      else: %{state | dequeue_overlay: %{items: items, selected: 0}}
  end

  defp dispatch_app_action("app.message.followUp", %{loader: %Components.Loader{}} = state, _key) do
    text = state.input.value

    if text == "" do
      state
    else
      if state.session, do: CoderSession.follow_up(state.session, text)
      input = %{state.input | value: "", cursor: 0}
      %{state | input: input, notification: "Follow-up queued"}
    end
  end

  defp dispatch_app_action("app.message.followUp", state, _key), do: handle_event_key(state, %Key{key: :enter})

  defp dispatch_app_action("app.model.cycleForward", %{models: []} = state, _key), do: state

  defp dispatch_app_action("app.model.cycleForward", state, _key) do
    new_model = cycle_model(state.models, state.model, :next)
    if state.session, do: CoderSession.set_model(state.session, new_model)

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
    if state.session, do: CoderSession.set_model(state.session, new_model)

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
    %{state | model_selector: ms}
  end

  defp dispatch_app_action(_action, state, _key), do: state

  defp handle_event_key(%{input: %{value: ""}} = state, %Key{key: :escape}), do: %{state | exit: true}

  defp handle_event_key(%{input: input} = state, %Key{key: :escape}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  defp handle_event_key(%{input: %{value: ""}, banner: %_{} = banner} = state, %Key{key: ??, modifiers: []} = key),
    do: %{state | banner: Components.WelcomeBanner.handle_key(banner, key)}

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
    cmd = String.downcase(String.trim(command))
    dispatch_slash(cmd, state, new_input, value)
  end

  defp handle_submit(state, new_input, "!" <> rest) do
    command = String.trim_leading(rest, " ")
    id = make_ref()
    be = BashExecution.new(command, state.theme, id: id)
    interactive_pid = self()

    Task.start(fn ->
      {output, exit_code} = System.shell(command, stderr_to_stdout: true)
      send(interactive_pid, {:bash_done, id, output, exit_code})
    end)

    %{state | input: %{new_input | value: "", cursor: 0}, transcript: state.transcript ++ [be]}
  end

  defp handle_submit(state, new_input, value), do: do_handle_submit(state, new_input, value)

  defp dispatch_slash(cmd, state, new_input, _value) when cmd in ~w(help clear compact cost model theme config) do
    dispatch_slash_command(cmd, %{state | input: %{new_input | value: "", cursor: 0}})
  end

  defp dispatch_slash(cmd, state, new_input, value) do
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

  defp do_handle_submit(state, new_input, value) do
    send_text = if state.expand_prompt_fn, do: state.expand_prompt_fn.(value), else: value
    if state.session, do: CoderSession.prompt(state.session, value, send_text)
    user_msg = if state.theme, do: UserMessage.new(value, state.theme), else: {:user, value}
    %{state | input: %{new_input | value: "", cursor: 0}, transcript: state.transcript ++ [user_msg]}
  end

  defp dispatch_slash_command("clear", state), do: %{state | transcript: []}

  defp dispatch_slash_command("model", state) do
    current_id = state.model && state.model.id
    ms = ModelSelector.new(state.models, state.theme, current: current_id)
    %{state | model_selector: ms}
  end

  defp dispatch_slash_command("help", state),
    do: %{state | notification: "Commands: /clear /compact /cost /model /theme /config"}

  defp dispatch_slash_command("cost", state) do
    f = state.footer

    msg =
      "$#{Float.round(f.cost, 4)} · ↑#{Footer.format_tokens(f.input_tokens)} ↓#{Footer.format_tokens(f.output_tokens)}"

    %{state | notification: msg}
  end

  defp dispatch_slash_command("compact", state) do
    if state.session, do: Task.start(fn -> CoderSession.compact(state.session, []) end)
    state
  end

  defp dispatch_slash_command("theme", state), do: %{state | notification: "Theme picker not yet implemented"}

  defp dispatch_slash_command("config", state), do: %{state | notification: "Config: use --help for startup options"}

  defp try_extension_shortcut([], _key, _state), do: :pass

  defp try_extension_shortcut([{match_fn, handler} | rest], key, state) do
    if match_fn.(key) do
      {:consumed, handler.(state)}
    else
      try_extension_shortcut(rest, key, state)
    end
  end

  # --- transcript updates ---

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.MessageUpdate} = ev, theme),
    do: apply_partial(transcript, ev.partial, theme)

  defp update_transcript(transcript, %{__struct__: MessageEnd} = ev, theme),
    do: finalize_assistant(transcript, ev.message, theme)

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.ToolExecutionStart} = ev, theme) do
    te = ToolExecution.new(ev.tool_name, ev.tool_call_id, ev.args, theme)
    transcript ++ [te]
  end

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.ToolExecutionEnd} = ev, _theme) do
    update_tool_execution(transcript, ev.tool_call_id, fn te ->
      result_text = extract_tool_result_text(ev.result)
      is_error = Map.get(ev.result, :is_error?, false)
      ToolExecution.set_result(te, result_text, is_error)
    end)
  end

  defp update_transcript(transcript, _, _theme), do: transcript

  defp update_footer(footer, %{__struct__: MessageEnd, message: msg}) do
    usage = Map.get(msg, :usage, %{})
    cost_struct = Map.get(usage, :cost, %{})
    new_input = footer.input_tokens + Map.get(usage, :input, 0)

    context_percent =
      if footer.context_window > 0,
        do: new_input / footer.context_window * 100.0

    %{
      footer
      | input_tokens: new_input,
        output_tokens: footer.output_tokens + Map.get(usage, :output, 0),
        cache_read: footer.cache_read + Map.get(usage, :cache_read, 0),
        cache_write: footer.cache_write + Map.get(usage, :cache_write, 0),
        cost: footer.cost + Map.get(cost_struct, :total, 0.0),
        context_percent: context_percent
    }
  end

  defp update_footer(footer, _), do: footer

  defp apply_partial(transcript, partial, theme) do
    content = extract_content_blocks(partial)

    case find_last_assistant(transcript) do
      {idx, %AssistantMessage{} = msg} ->
        updated = AssistantMessage.update_content(msg, content: content)
        List.replace_at(transcript, idx, updated)

      _ ->
        msg = AssistantMessage.new(theme, content: content)
        transcript ++ [msg]
    end
  end

  defp finalize_assistant(transcript, msg, theme) do
    content = extract_content_blocks(msg)
    stop_reason = extract_stop_reason(msg)
    error_message = Map.get(msg, :error_message)
    has_tool_calls = has_tool_calls?(msg)

    updates = [
      content: content,
      stop_reason: stop_reason,
      error_message: error_message,
      has_tool_calls: has_tool_calls
    ]

    case find_last_assistant(transcript) do
      {idx, %AssistantMessage{} = existing} ->
        updated = AssistantMessage.update_content(existing, updates)
        List.replace_at(transcript, idx, updated)

      _ ->
        msg = AssistantMessage.new(theme, updates)
        transcript ++ [msg]
    end
  end

  defp find_last_assistant(transcript) do
    result =
      transcript
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn
        {%AssistantMessage{}, _idx} -> true
        _ -> false
      end)

    case result do
      {msg, idx} ->
        has_boundary_after =
          transcript
          |> Enum.drop(idx + 1)
          |> Enum.any?(fn
            %UserMessage{} -> true
            {:user, _} -> true
            %ToolExecution{} -> true
            _ -> false
          end)

        if has_boundary_after, do: nil, else: {idx, msg}

      nil ->
        nil
    end
  end

  defp update_tool_execution(transcript, tool_call_id, update_fn) do
    idx =
      Enum.find_index(transcript, fn
        %ToolExecution{tool_call_id: id} -> id == tool_call_id
        _ -> false
      end)

    if idx do
      List.update_at(transcript, idx, update_fn)
    else
      transcript
    end
  end

  defp extract_content_blocks(%{content: content}) when is_list(content) do
    Enum.flat_map(content, fn
      %OctoPi.AI.Content.Text{text: text} -> [{:text, text}]
      %OctoPi.AI.Content.Thinking{thinking: text} -> [{:thinking, text}]
      _ -> []
    end)
  end

  defp extract_content_blocks(_), do: []

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
  Render the current state into a flat list of lines ready for the
  Renderer. Components are concatenated in layout order — the
  Renderer handles terminal mechanics (scrolling, cursor, clearing).
  """
  @spec render(t()) :: [binary()]
  def render(%{input: input, width: width} = state) do
    render(state, Components.Input.render(input, width))
  end

  @spec render(t(), [binary()]) :: [binary()]
  def render(%{custom_widget: {_, component}, width: width}, _input_lines) do
    [""] ++ component.render.(width)
  end

  def render(
        %{transcript: transcript, footer: footer, banner: banner, loader: loader, width: width} = state,
        input_lines
      ) do
    banner_lines = header_lines(Map.get(state.ui_overrides, :header), banner, width)
    resource_lines = render_resource_sections(state.loaded_resources, state.theme, state.tools_expanded)
    transcript_lines = render_transcript(transcript, width, state.thinking_visible)
    loader_lines = render_loader(loader, width, state.theme)
    dropdown_lines = Components.Input.render_dropdown(state.input, width)
    notification_lines = render_notification(state.notification, width)
    footer_lines = footer_lines(Map.get(state.ui_overrides, :footer), footer, state.footer_data, width)

    all =
      banner_lines ++
        resource_lines ++
        transcript_lines ++ loader_lines ++ input_lines ++ dropdown_lines ++ notification_lines ++ footer_lines

    [""] ++ all
  end

  defp build_custom_theme(%{theme: nil}), do: %{fg: fn _color, text -> text end}
  defp build_custom_theme(%{theme: theme}), do: %{fg: fn color, text -> Theme.fg(theme, color, text) end}

  defp default_working_message, do: "Thinking…"

  defp render_loader(nil, _width, _theme), do: []
  defp render_loader(%Components.Loader{} = loader, width, theme), do: Components.Loader.render(loader, width, theme)

  defp render_notification(nil, _width), do: []
  defp render_notification(text, _width), do: [dim(text)]

  defp next_thinking_level(:off), do: :low
  defp next_thinking_level(:low), do: :medium
  defp next_thinking_level(:medium), do: :high
  defp next_thinking_level(:high), do: :off
  defp next_thinking_level(_), do: :low

  defp thinking_level_label(level), do: to_string(level)

  defp handle_dequeue_key(state, ov, %Key{key: :up}),
    do: %{state | dequeue_overlay: %{ov | selected: max(0, ov.selected - 1)}}

  defp handle_dequeue_key(state, ov, %Key{key: :down}) do
    max_sel = max(0, length(ov.items) - 1)
    %{state | dequeue_overlay: %{ov | selected: min(max_sel, ov.selected + 1)}}
  end

  defp handle_dequeue_key(state, ov, %Key{key: k}) when k in [:delete, :backspace] do
    new_items = List.delete_at(ov.items, ov.selected)

    if new_items == [] do
      %{state | dequeue_overlay: nil}
    else
      max_sel = max(0, length(new_items) - 1)
      %{state | dequeue_overlay: %{ov | items: new_items, selected: min(ov.selected, max_sel)}}
    end
  end

  defp handle_dequeue_key(state, ov, %Key{key: :escape}) do
    Enum.each(ov.items, fn
      {:steering, msg} -> if state.session, do: CoderSession.steer(state.session, msg)
      {:follow_up, msg} -> if state.session, do: CoderSession.follow_up(state.session, msg)
    end)

    %{state | dequeue_overlay: nil}
  end

  defp handle_dequeue_key(state, _ov, _key), do: state

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

  defp render_banner(nil, _width), do: []

  defp render_banner(banner, width) do
    case Components.WelcomeBanner.render(banner, width) do
      [] -> []
      lines -> lines ++ [""]
    end
  end

  defp header_lines(render_fn, _banner, width) when is_function(render_fn, 1), do: render_fn.(width)
  defp header_lines(nil, banner, width), do: render_banner(banner, width)

  defp footer_lines(render_fn, footer, footer_data_pid, width) when is_function(render_fn, 2),
    do: render_fn.(width, build_footer_context(footer, footer_data_pid))

  defp footer_lines(nil, footer, _footer_data_pid, width), do: Footer.render(footer, width)

  defp build_footer_context(footer, footer_data_pid) do
    %{
      get_git_branch: fn -> branch_from(footer_data_pid) end,
      get_extension_statuses: fn -> footer.extension_statuses end,
      on_branch_change: fn _cb -> fn -> :ok end end
    }
  end

  defp branch_from(nil), do: nil
  defp branch_from(pid), do: FooterData.get_git_branch(pid)

  defp render_resource_sections(nil, _theme, _expanded), do: []

  defp render_resource_sections(resources, theme, expanded) do
    [
      render_context_section(resources.context_files, theme, expanded),
      render_skills_section(resources.skills, theme, expanded),
      render_prompts_section(resources.prompt_templates, theme, expanded)
    ]
    |> Enum.reject(&(&1 == []))
    |> Enum.flat_map(&(&1 ++ [""]))
  end

  defp render_context_section([], _theme, _expanded), do: []

  defp render_context_section(files, theme, expanded) do
    header = section_header(theme, "Context")

    body =
      if expanded do
        Enum.map_join(files, "\n", &("  " <> dim(&1.path)))
      else
        names = Enum.map_join(files, ", ", &Path.basename(&1.path))
        dim("  #{names}")
      end

    [header, body]
  end

  defp render_skills_section([], _theme, _expanded), do: []

  defp render_skills_section(skills, theme, expanded) do
    header = section_header(theme, "Skills")

    body =
      if expanded do
        Enum.map_join(skills, "\n", &("  " <> dim(&1.name)))
      else
        names = Enum.map_join(skills, ", ", & &1.name)
        dim("  #{names}")
      end

    [header, body]
  end

  defp render_prompts_section([], _theme, _expanded), do: []

  defp render_prompts_section(templates, theme, expanded) do
    header = section_header(theme, "Prompts")

    body =
      if expanded do
        Enum.map_join(templates, "\n", &("  " <> dim("/#{&1.name}")))
      else
        names = Enum.map_join(templates, ", ", &"/#{&1.name}")
        dim("  #{names}")
      end

    [header, body]
  end

  defp section_header(nil, name), do: "[#{name}]"
  defp section_header(theme, name), do: Theme.fg(theme, :md_heading, "[#{name}]")

  defp dim(text), do: "\e[2m#{text}\e[22m"

  defp render_transcript(transcript, width, thinking_visible) do
    transcript
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      spacer = if idx > 0 and match?(%UserMessage{}, entry), do: [""], else: []
      spacer ++ render_entry(entry, width, thinking_visible)
    end)
  end

  defp render_entry(%AssistantMessage{} = msg, width, thinking_visible) do
    AssistantMessage.render(%{msg | hide_thinking: not thinking_visible}, width)
  end

  defp render_entry(%mod{} = component, width, _thinking_visible), do: mod.render(component, width)

  defp render_entry({:user, text}, width, _thinking_visible) do
    WrapAnsi.wrap("> #{text}", width)
  end

  defp render_entry({:assistant, text, _}, width, _thinking_visible) do
    WrapAnsi.wrap(Safe.sanitize(text), width)
  end
end
