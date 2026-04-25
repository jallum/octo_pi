defmodule OctoPi.TUI.Interactive do
  @moduledoc """
  Main loop for `mix pi` interactive mode.

  Composes the Phase 4 pieces end-to-end: `Terminal` owns the tty,
  `StdinFSM` assembles sequences, `KeyParser` decodes them, the
  `Input` component accumulates the prompt, and the `Renderer`
  paints the transcript + input to the screen. Agent events from
  `OctoPi.Agent.Session` drive the transcript updates.

  The state machine is a pure function: `handle_event/2` takes a
  state and an event (key, agent event, or resize) and returns a
  new state. Tests drive it directly without any tty.
  `run/1` spins up the real plumbing and pumps messages into
  `handle_event/2`.
  """

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Event.MessageEnd
  alias OctoPi.Coder
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.TUI.Components
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Components.UserMessage
  alias OctoPi.TUI.EventLogger
  alias OctoPi.TUI.Events
  alias OctoPi.TUI.FooterData
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.KeyParser
  alias OctoPi.TUI.RawMode
  alias OctoPi.TUI.Renderer
  alias OctoPi.TUI.Safe
  alias OctoPi.TUI.StdinFSM
  alias OctoPi.TUI.Terminal
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  @type resource_data :: %{
          context_files: [%{path: String.t()}],
          skills: [%{name: String.t()}],
          prompt_templates: [%{name: String.t()}]
        }

  @type t :: %__MODULE__{
          session: pid() | nil,
          input: Components.Input.t(),
          transcript: [struct()],
          footer: Footer.t(),
          footer_data: pid() | nil,
          theme: Theme.t(),
          width: pos_integer(),
          height: pos_integer(),
          exit: boolean(),
          paste_buffer: String.t() | nil,
          tools_expanded: boolean(),
          loader: Components.Loader.t() | nil,
          working_message: String.t() | nil,
          notification: String.t() | nil,
          banner: Components.WelcomeBanner.t() | nil,
          loaded_resources: resource_data() | nil,
          expand_prompt_fn: (String.t() -> String.t()) | nil,
          ui_overrides: map(),
          dialog: tuple() | nil,
          extension_shortcuts: [{(Key.t() -> boolean()), (t() -> t())}],
          debug_render_log: IO.device() | nil
        }

  defstruct session: nil,
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
            paste_buffer: nil,
            tools_expanded: false,
            loader: nil,
            working_message: nil,
            notification: nil,
            ui_overrides: %{},
            dialog: nil,
            extension_shortcuts: [],
            debug_render_log: nil

  @doc """
  Build a `UIContext` whose functions send messages to `interactive_pid`.

  Extension code calls these functions from its own process; the
  Interactive receive loop handles the messages and replies.
  """
  @spec build_ui_context(pid()) :: UIContext.t()
  def build_ui_context(interactive_pid) do
    req = fn msg ->
      ref = make_ref()
      send(interactive_pid, {:ui_request, self(), ref, msg})

      receive do
        {:ui_reply, ^ref, value} -> value
      after
        5_000 -> raise RuntimeError, "UIContext request timed out: #{inspect(msg)}"
      end
    end

    fire = fn msg ->
      send(interactive_pid, {:ui_fire, msg})
      :ok
    end

    UIContext.bind(UIContext.new(), %{
      get_editor_text: fn -> req.(:get_editor_text) end,
      get_theme: fn -> req.(:get_theme) end,
      get_all_themes: fn -> req.(:get_all_themes) end,
      get_tools_expanded: fn -> req.(:get_tools_expanded) end,
      set_editor_text: fn text -> fire.({:set_editor_text, text}) end,
      paste_to_editor: fn text -> fire.({:paste_to_editor, text}) end,
      set_theme: fn name -> fire.({:set_theme, name}) end,
      set_tools_expanded: fn val -> fire.({:set_tools_expanded, val}) end,
      notify: fn text -> fire.({:notify, text}) end,
      set_status: fn text -> fire.({:set_status, text}) end,
      set_working_message: fn msg -> fire.({:set_working_message, msg}) end,
      set_working_indicator: fn val -> fire.({:set_working_indicator, val}) end,
      set_hidden_thinking_label: fn label -> fire.({:set_hidden_thinking_label, label}) end,
      set_widget: fn w -> fire.({:set_widget, w}) end,
      set_footer: fn f -> fire.({:set_footer, f}) end,
      set_header: fn h -> fire.({:set_header, h}) end,
      set_title: fn t -> fire.({:set_title, t}) end,
      set_editor_component: fn c -> fire.({:set_editor_component, c}) end,
      add_autocomplete_provider: fn p -> fire.({:add_autocomplete_provider, p}) end,
      select: fn opts, kw ->
        ref = make_ref()
        send(interactive_pid, {:ui_request, self(), ref, {:select, ref, opts, kw}})

        receive do
          {:ui_reply, ^ref, val} -> val
        end
      end,
      confirm: fn prompt, kw ->
        ref = make_ref()
        send(interactive_pid, {:ui_request, self(), ref, {:confirm, ref, prompt, kw}})

        receive do
          {:ui_reply, ^ref, val} -> val
        end
      end,
      input: fn prompt, kw ->
        ref = make_ref()
        send(interactive_pid, {:ui_request, self(), ref, {:input, ref, prompt, kw}})

        receive do
          {:ui_reply, ^ref, val} -> val
        end
      end,
      editor: fn content, kw ->
        ref = make_ref()
        send(interactive_pid, {:ui_request, self(), ref, {:editor, ref, content, kw}})

        receive do
          {:ui_reply, ^ref, val} -> val
        end
      end,
      custom: fn term, kw ->
        ref = make_ref()
        send(interactive_pid, {:ui_request, self(), ref, {:custom, ref, term, kw}})

        receive do
          {:ui_reply, ^ref, val} -> val
        end
      end
    })
  end

  @doc """
  Handle a UIContext request, returning `{new_state, reply}`.

  Getters return `{state, value}`. Setters return `{state, :ok}`.
  Blocking dialogs return `{state, :pending}` — the caller must
  wait for resolution through key events.
  """
  @spec handle_ui_request(t(), term()) :: {t(), term()}
  def handle_ui_request(state, :get_editor_text), do: {state, state.input.value}
  def handle_ui_request(state, :get_tools_expanded), do: {state, state.tools_expanded}
  def handle_ui_request(state, :get_theme), do: {state, state.theme && state.theme.name}

  def handle_ui_request(state, :get_all_themes), do: {state, Theme.available_themes()}

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

  def handle_ui_request(state, {:set_status, text}) do
    {%{state | ui_overrides: Map.put(state.ui_overrides, :status, text)}, :ok}
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

  def handle_ui_request(state, {:select, ref, options, opts}) do
    {%{state | dialog: {:select, ref, options, opts}}, :pending}
  end

  def handle_ui_request(state, {:confirm, ref, prompt, opts}) do
    {%{state | dialog: {:confirm, ref, prompt, opts}}, :pending}
  end

  def handle_ui_request(state, {:input, ref, prompt, opts}) do
    {%{state | dialog: {:input, ref, prompt, opts}}, :pending}
  end

  def handle_ui_request(state, {:editor, ref, content, opts}) do
    {%{state | dialog: {:editor, ref, content, opts}}, :pending}
  end

  def handle_ui_request(state, {:custom, ref, term, opts}) do
    {%{state | dialog: {:custom, ref, term, opts}}, :pending}
  end

  @doc """
  Entry point for the CLI. Wires up the full pipeline — Session,
  Terminal, StdinFSM, Renderer — subscribes to the events each
  produces, and runs the receive loop until `state.exit` flips.

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
  """
  @spec run(keyword()) :: :ok
  def run(opts) do
    raw_mode_fn = Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1)
    skip_raw_mode = Keyword.get(opts, :skip_raw_mode, false)
    old_trap = Process.flag(:trap_exit, true)

    try do
      do_run(opts)
    after
      safe_raw_mode_exit(raw_mode_fn, skip_raw_mode)
      Process.flag(:trap_exit, old_trap)
    end
  end

  defp do_run(opts) do
    {w, h} = Keyword.get_lazy(opts, :dimensions, &detect_dimensions/0)
    write_fn = Keyword.get(opts, :write_fn, &IO.write/1)
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    model = Keyword.fetch!(opts, :model)

    debug_render_log =
      if Keyword.get(opts, :debug_render, false) do
        path = Path.join(cwd, "debug_render.log")
        {:ok, fd} = File.open(path, [:write, :utf8])
        fd
      end

    debug_events_log =
      if Keyword.get(opts, :debug_events, false) do
        path = Path.join(cwd, "debug_events.log")
        EventLogger.attach(path)
      end

    session = start_agent_session(opts)
    {:ok, terminal} = start_terminal(opts, write_fn)
    {:ok, fsm} = StdinFSM.start_link(subscriber: self())
    {:ok, renderer} = Renderer.start_link(width: w, height: h, csi_2026?: true)
    {:ok, footer_data} = FooterData.start_link(cwd: cwd)

    {:ok, _} = Registry.register(Events, {:stdin_chunk, terminal}, nil)
    {:ok, _} = Registry.register(Events, {:resize, terminal}, nil)
    OctoPi.Agent.subscribe(session, self(), :async)

    theme = Theme.load_builtin(:dark, Theme.detect_color_mode())

    footer = %Footer{
      cwd: cwd,
      model_id: model.id,
      provider: model.provider,
      context_window: model.context_window,
      git_branch: FooterData.get_git_branch(footer_data)
    }

    loaded_resources = build_loaded_resources(opts)

    state = %__MODULE__{
      session: session,
      input: %Components.Input{width: w, height: h, theme: theme},
      width: w,
      height: h,
      theme: theme,
      banner: Components.WelcomeBanner.new(theme, model: model.id),
      footer: footer,
      footer_data: footer_data,
      loaded_resources: loaded_resources,
      expand_prompt_fn: Keyword.get(opts, :expand_prompt_fn),
      debug_render_log: debug_render_log
    }

    state = render_frame(state, renderer, terminal)

    loop(state, fsm, renderer, terminal)

    if debug_render_log, do: File.close(debug_render_log)
    if debug_events_log, do: EventLogger.detach(debug_events_log)
    shutdown(terminal, fsm, renderer, footer_data)
    :ok
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

  defp safe_raw_mode_exit(_fun, true), do: :ok

  defp safe_raw_mode_exit(fun, false) do
    fun.(:exit)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  defp start_agent_session(opts) do
    cwd = Keyword.get(opts, :cwd, File.cwd!())
    tools = Keyword.get_lazy(opts, :tools, fn -> Coder.default_tools(cwd) end)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        Coder.SystemPrompt.render(cwd: cwd, tools: tools)
      end)

    session_opts =
      put_if_present(
        [model: Keyword.fetch!(opts, :model), tools: tools, system_prompt: system_prompt],
        :transport,
        opts[:transport]
      )

    {:ok, pid} = OctoPi.Agent.start_session(session_opts)
    pid
  end

  defp put_if_present(kw, _k, nil), do: kw
  defp put_if_present(kw, k, v), do: Keyword.put(kw, k, v)

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

  defp start_terminal(opts, write_fn) do
    terminal_opts =
      opts
      |> Keyword.take([
        :skip_raw_mode,
        :skip_sigwinch,
        :auto_start_reader,
        :dimensions,
        :raw_mode_fn,
        :tty_fn
      ])
      |> Keyword.put(:name, Keyword.get(opts, :terminal_name, Terminal))
      |> Keyword.put(:write_fn, write_fn)

    Terminal.start_link(terminal_opts)
  end

  # --- main message loop ---

  @loader_interval_ms 80

  defp loop(%__MODULE__{exit: true}, _fsm, _renderer, _terminal), do: :ok

  defp loop(%__MODULE__{loader: %Components.Loader{}} = state, fsm, renderer, terminal) do
    receive do
      msg -> handle_loop_msg(state, msg, fsm, renderer, terminal)
    after
      @loader_interval_ms ->
        state
        |> handle_event(:loader_tick)
        |> advance(fsm, renderer, terminal)
    end
  end

  defp loop(state, fsm, renderer, terminal) do
    receive do
      msg -> handle_loop_msg(state, msg, fsm, renderer, terminal)
    end
  end

  defp handle_loop_msg(state, {:stdin_chunk, bin}, fsm, renderer, terminal) do
    :ok = StdinFSM.process(fsm, bin)
    loop(state, fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:stdin_event, seq}, fsm, renderer, terminal) do
    parsed = KeyParser.parse(seq)
    :telemetry.execute([:octo_pi_tui, :key, :event], %{}, %{parsed: parsed})

    state
    |> handle_event(parsed)
    |> advance(fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:resize, w, h} = resize_msg, fsm, renderer, terminal) do
    Renderer.resize(renderer, w, h)

    state
    |> handle_event(resize_msg)
    |> advance(fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:octo_pi_agent_event, _} = agent_msg, fsm, renderer, terminal) do
    state
    |> handle_event(agent_msg)
    |> advance(fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:ui_request, from, ref, ui_msg}, fsm, renderer, terminal) do
    {new_state, reply} = handle_ui_request(state, ui_msg)
    if reply != :pending, do: send(from, {:ui_reply, ref, reply})
    advance(new_state, fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:ui_fire, ui_msg}, fsm, renderer, terminal) do
    {new_state, _reply} = handle_ui_request(state, ui_msg)
    advance(new_state, fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, {:EXIT, _pid, _reason}, fsm, renderer, terminal) do
    loop(%{state | exit: true}, fsm, renderer, terminal)
  end

  defp handle_loop_msg(state, _msg, fsm, renderer, terminal) do
    loop(state, fsm, renderer, terminal)
  end

  defp advance(new_state, fsm, renderer, terminal) do
    new_state = render_frame(new_state, renderer, terminal)
    loop(new_state, fsm, renderer, terminal)
  end

  defp render_frame(state, renderer, terminal) do
    input = Components.Input.update_scroll(state.input, state.width)
    state = %{state | input: input}
    input_lines = Components.Input.render(input, state.width)
    lines = render(state, input_lines)

    if state.debug_render_log, do: log_overwide(state.debug_render_log, lines, state.width)

    cursor_seq = cursor_position(state, input_lines, lines)
    {:ok, bytes} = Renderer.render(renderer, lines, cursor_seq)

    if bytes != "", do: Terminal.write(terminal, bytes)
    state
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

  defp cursor_position(%__MODULE__{input: input, width: width, height: height, footer: footer}, input_lines, lines) do
    {crow, ccol} = Components.Input.cursor_rc(input, width)
    footer_height = length(Footer.render(footer, width))
    input_end = length(lines) - footer_height
    input_start = input_end - length(input_lines)
    viewport_top = max(0, length(lines) - height)
    screen_row = input_start + crow - viewport_top + 1
    "\e[#{screen_row};#{ccol + 1}H"
  end

  defp shutdown(terminal, fsm, renderer, footer_data) do
    pids = Enum.reject([footer_data, renderer, fsm, terminal], &is_nil/1)

    Enum.each(pids, fn pid ->
      if Process.alive?(pid), do: GenServer.stop(pid, :normal)
    end)
  end

  # --- pure state-machine ---

  @doc """
  Apply an event to a state and return the updated state.
  Events:
    * `{:key, %Key{}}` or `{:char, binary}` — keyboard input.
    * `{:octo_pi_agent_event, event}` — from the Agent subscription.
    * `{:resize, w, h}` — from Terminal's SIGWINCH broadcast.
  """
  @spec handle_event(t(), term()) :: t()

  def handle_event(state, {:key, %Key{key: ?c, modifiers: [:ctrl]}}), do: %{state | exit: true}

  def handle_event(state, {:key, %Key{key: ?o, modifiers: [:ctrl]}}) do
    expanded = !state.tools_expanded

    banner =
      case state.banner do
        %Components.WelcomeBanner{} = b -> %{b | expanded: expanded}
        other -> other
      end

    %{state | tools_expanded: expanded, banner: banner}
  end

  def handle_event(%{extension_shortcuts: shortcuts} = state, {:key, %Key{} = key}) when shortcuts != [] do
    case try_extension_shortcut(shortcuts, key, state) do
      {:consumed, new_state} -> new_state
      :pass -> handle_event_key(state, key)
    end
  end

  def handle_event(state, {:key, %Key{} = key}), do: handle_event_key(state, key)

  def handle_event(state, :paste_start), do: %{state | paste_buffer: ""}

  def handle_event(%{paste_buffer: buf} = state, {:char, c}) when is_binary(buf), do: %{state | paste_buffer: buf <> c}

  def handle_event(%{paste_buffer: buf, input: input} = state, :paste_end) when is_binary(buf),
    do: %{state | input: Components.Input.paste(input, buf), paste_buffer: nil}

  def handle_event(state, :paste_end), do: %{state | paste_buffer: nil}

  def handle_event(%{input: %{value: ""}, banner: %_{} = banner} = state, {:char, "?"}) do
    %{state | banner: Components.WelcomeBanner.handle_key(banner, %Key{key: ??})}
  end

  def handle_event(%{input: input} = state, {:char, c}), do: %{state | input: Components.Input.insert(input, c)}

  def handle_event(state, {:octo_pi_agent_event, %Event.AgentStart{}}) do
    message = state.working_message || default_working_message()
    %{state | loader: Components.Loader.new(message: message)}
  end

  def handle_event(state, {:octo_pi_agent_event, %Event.AgentEnd{} = event}) do
    %{
      state
      | loader: nil,
        working_message: nil,
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

  def handle_event(state, {:resize, w, h}),
    do: %{state | width: w, height: h, input: %{state.input | width: w, height: h}}

  def handle_event(%{loader: %Components.Loader{} = loader} = state, :loader_tick),
    do: %{state | loader: Components.Loader.advance_frame(loader)}

  def handle_event(state, _), do: state

  defp handle_event_key(%{input: %{value: ""}} = state, %Key{key: :escape}), do: %{state | exit: true}

  defp handle_event_key(%{input: input} = state, %Key{key: :escape}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  defp handle_event_key(%{input: input, session: session} = state, %Key{key: :enter}) do
    case Components.Input.handle_key(input, %Key{key: :enter}) do
      {new_input, [{:submit, value}]} when value != "" ->
        prompt = if state.expand_prompt_fn, do: state.expand_prompt_fn.(value), else: value
        if session, do: OctoPi.Agent.prompt(session, prompt)

        user_msg =
          if state.theme do
            UserMessage.new(value, state.theme)
          else
            {:user, value}
          end

        %{
          state
          | input: %{new_input | value: "", cursor: 0},
            transcript: state.transcript ++ [user_msg]
        }

      _ ->
        state
    end
  end

  defp handle_event_key(%{input: input} = state, %Key{} = key) do
    case Components.Input.handle_key(input, key) do
      {new_input, _events} -> %{state | input: new_input}
      new_input -> %{state | input: new_input}
    end
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

    %{
      footer
      | input_tokens: footer.input_tokens + Map.get(usage, :input, 0),
        output_tokens: footer.output_tokens + Map.get(usage, :output, 0),
        cache_read: footer.cache_read + Map.get(usage, :cache_read, 0),
        cache_write: footer.cache_write + Map.get(usage, :cache_write, 0),
        cost: footer.cost + Map.get(cost_struct, :total, 0.0)
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
  def render(
        %{transcript: transcript, footer: footer, banner: banner, loader: loader, width: width, height: height} = state,
        input_lines
      ) do
    banner_lines = render_banner(banner, width)
    resource_lines = render_resource_sections(state.loaded_resources, state.theme, state.tools_expanded)
    transcript_lines = render_transcript(transcript, width)
    loader_lines = render_loader(loader, width, state.theme)
    footer_lines = Footer.render(footer, width)

    all = banner_lines ++ resource_lines ++ transcript_lines ++ loader_lines ++ input_lines ++ footer_lines
    len = length(all)
    if len < height, do: List.duplicate("", height - len) ++ all, else: all
  end

  defp default_working_message, do: "Thinking…"

  defp render_loader(nil, _width, _theme), do: []

  defp render_loader(%Components.Loader{} = loader, width, theme), do: Components.Loader.render(loader, width, theme)

  defp render_banner(nil, _width), do: []

  defp render_banner(banner, width) do
    case Components.WelcomeBanner.render(banner, width) do
      [] -> []
      lines -> lines ++ [""]
    end
  end

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

  defp render_transcript(transcript, width) do
    transcript
    |> Enum.with_index()
    |> Enum.flat_map(fn {entry, idx} ->
      spacer = if idx > 0 and match?(%UserMessage{}, entry), do: [""], else: []
      spacer ++ render_entry(entry, width)
    end)
  end

  defp render_entry(%mod{} = component, width), do: mod.render(component, width)

  defp render_entry({:user, text}, width) do
    WrapAnsi.wrap("> #{text}", width)
  end

  defp render_entry({:assistant, text, _}, width) do
    WrapAnsi.wrap(Safe.sanitize(text), width)
  end
end
