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

  alias OctoPi.TUI.{
    Components,
    Events,
    FooterData,
    Key,
    KeyParser,
    RawMode,
    Renderer,
    Safe,
    StdinFSM,
    Terminal,
    Theme,
    WrapAnsi
  }

  alias Components.{AssistantMessage, Footer, ToolExecution, UserMessage}
  alias OctoPi.Coder

  alias OctoPi.Coder.Extension.UIContext

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
          working_message: String.t() | nil,
          notification: String.t() | nil,
          banner: Components.WelcomeBanner.t() | nil,
          ui_overrides: map(),
          dialog: tuple() | nil,
          extension_shortcuts: [{(Key.t() -> boolean()), (t() -> t())}]
        }

  defstruct session: nil,
            input: %Components.Input{},
            transcript: [],
            footer: %Footer{},
            footer_data: nil,
            theme: nil,
            banner: nil,
            width: 80,
            height: 24,
            exit: false,
            paste_buffer: nil,
            tools_expanded: false,
            working_message: nil,
            notification: nil,
            ui_overrides: %{},
            dialog: nil,
            extension_shortcuts: []

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

  def handle_ui_request(state, :get_all_themes),
    do: {state, Theme.available_themes()}

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
    {%{state | working_message: msg}, :ok}
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

    state = %__MODULE__{
      session: session,
      input: %Components.Input{width: w, height: h, theme: theme},
      width: w,
      height: h,
      theme: theme,
      banner: Components.WelcomeBanner.new(theme, model: model.id),
      footer: footer,
      footer_data: footer_data
    }

    state = render_frame(state, renderer, terminal)

    loop(state, fsm, renderer, terminal)

    shutdown(terminal, fsm, renderer, footer_data)
    :ok
  end

  defp detect_dimensions do
    w =
      case :io.columns() do
        {:ok, n} -> n
        _ -> 80
      end

    h =
      case :io.rows() do
        {:ok, n} -> n
        _ -> 24
      end

    {w, h}
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
      [model: Keyword.fetch!(opts, :model), tools: tools, system_prompt: system_prompt]
      |> put_if_present(:transport, opts[:transport])

    {:ok, pid} = OctoPi.Agent.start_session(session_opts)
    pid
  end

  defp put_if_present(kw, _k, nil), do: kw
  defp put_if_present(kw, k, v), do: Keyword.put(kw, k, v)

  defp start_terminal(opts, write_fn) do
    terminal_opts =
      opts
      |> Keyword.take([
        :skip_raw_mode,
        :skip_sigwinch,
        :auto_start_reader,
        :dimensions,
        :raw_mode_fn
      ])
      |> Keyword.put(:name, Keyword.get(opts, :terminal_name, Terminal))
      |> Keyword.put(:write_fn, write_fn)

    Terminal.start_link(terminal_opts)
  end

  # --- main message loop ---

  defp loop(%__MODULE__{exit: true}, _fsm, _renderer, _terminal), do: :ok

  defp loop(state, fsm, renderer, terminal) do
    receive do
      {:stdin_chunk, bin} ->
        :ok = StdinFSM.process(fsm, bin)
        loop(state, fsm, renderer, terminal)

      {:stdin_event, seq} ->
        state
        |> handle_event(KeyParser.parse(seq))
        |> advance(fsm, renderer, terminal)

      {:resize, w, h} = msg ->
        Renderer.resize(renderer, w, h)

        state
        |> handle_event(msg)
        |> advance(fsm, renderer, terminal)

      {:octo_pi_agent_event, _} = msg ->
        state
        |> handle_event(msg)
        |> advance(fsm, renderer, terminal)

      {:ui_request, from, ref, msg} ->
        {new_state, reply} = handle_ui_request(state, msg)
        if reply != :pending, do: send(from, {:ui_reply, ref, reply})
        advance(new_state, fsm, renderer, terminal)

      {:ui_fire, msg} ->
        {new_state, _reply} = handle_ui_request(state, msg)
        advance(new_state, fsm, renderer, terminal)

      {:EXIT, _pid, _reason} ->
        loop(%{state | exit: true}, fsm, renderer, terminal)
    end
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
    cursor_seq = cursor_position(state, input_lines, lines)
    {:ok, bytes} = Renderer.render(renderer, lines, cursor_seq)

    if bytes != "", do: Terminal.write(terminal, bytes)
    state
  end

  defp cursor_position(
         %__MODULE__{input: input, width: width, footer: footer},
         input_lines,
         lines
       ) do
    {crow, ccol} = Components.Input.cursor_rc(input, width)
    footer_height = length(Footer.render(footer, width))
    input_end = length(lines) - footer_height
    input_start = input_end - length(input_lines)
    "\e[#{input_start + crow + 1};#{ccol + 1}H"
  end

  defp shutdown(terminal, fsm, renderer, footer_data) do
    pids = [footer_data, renderer, fsm, terminal] |> Enum.reject(&is_nil/1)

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

  def handle_event(state, {:key, %Key{key: ?c, modifiers: [:ctrl]}}),
    do: %{state | exit: true}

  def handle_event(%{extension_shortcuts: shortcuts} = state, {:key, %Key{} = key})
      when shortcuts != [] do
    case try_extension_shortcut(shortcuts, key, state) do
      {:consumed, new_state} -> new_state
      :pass -> handle_event_key(state, key)
    end
  end

  def handle_event(state, {:key, %Key{} = key}), do: handle_event_key(state, key)

  def handle_event(state, :paste_start),
    do: %{state | paste_buffer: ""}

  def handle_event(%{paste_buffer: buf} = state, {:char, c}) when is_binary(buf),
    do: %{state | paste_buffer: buf <> c}

  def handle_event(%{paste_buffer: buf, input: input} = state, :paste_end) when is_binary(buf),
    do: %{state | input: Components.Input.paste(input, buf), paste_buffer: nil}

  def handle_event(state, :paste_end),
    do: %{state | paste_buffer: nil}

  def handle_event(%{input: %{value: ""}, banner: %_{} = banner} = state, {:char, "?"}) do
    %{state | banner: Components.WelcomeBanner.handle_key(banner, %Key{key: ??})}
  end

  def handle_event(%{input: input} = state, {:char, c}),
    do: %{state | input: Components.Input.insert(input, c)}

  def handle_event(state, {:octo_pi_agent_event, event}) do
    %{
      state
      | transcript: update_transcript(state.transcript, event, state.theme),
        footer: update_footer(state.footer, event)
    }
  end

  def handle_event(state, {:resize, w, h}),
    do: %{state | width: w, height: h, input: %{state.input | width: w, height: h}}

  def handle_event(state, _), do: state

  defp handle_event_key(%{input: %{value: ""}} = state, %Key{key: :escape}),
    do: %{state | exit: true}

  defp handle_event_key(%{input: input} = state, %Key{key: :escape}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  defp handle_event_key(%{input: input, session: session} = state, %Key{key: :enter}) do
    case Components.Input.handle_key(input, %Key{key: :enter}) do
      {new_input, [{:submit, value}]} when value != "" ->
        if session, do: OctoPi.Agent.prompt(session, value)

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

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.MessageEnd} = ev, theme),
    do: finalize_assistant(transcript, ev.message, theme)

  defp update_transcript(
         transcript,
         %{__struct__: OctoPi.Agent.Event.ToolExecutionStart} = ev,
         theme
       ) do
    te = ToolExecution.new(ev.tool_name, ev.tool_call_id, %{}, theme)
    transcript ++ [te]
  end

  defp update_transcript(
         transcript,
         %{__struct__: OctoPi.Agent.Event.ToolExecutionEnd} = ev,
         _theme
       ) do
    update_tool_execution(transcript, ev.tool_call_id, fn te ->
      result_text = extract_tool_result_text(ev.result)
      is_error = Map.get(ev.result, :is_error?, false)
      ToolExecution.set_result(te, result_text, is_error)
    end)
  end

  defp update_transcript(transcript, _, _theme), do: transcript

  defp update_footer(footer, %{__struct__: OctoPi.Agent.Event.MessageEnd, message: msg}) do
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
        %{
          transcript: transcript,
          footer: footer,
          banner: banner,
          width: width,
          height: height
        },
        input_lines
      ) do
    banner_lines = render_banner(banner, width)
    transcript_lines = Enum.flat_map(transcript, &render_entry(&1, width))
    footer_lines = Footer.render(footer, width)

    all = banner_lines ++ transcript_lines ++ input_lines ++ footer_lines
    fit_to_height(all, height)
  end

  defp fit_to_height(lines, height) do
    len = length(lines)

    cond do
      len == height -> lines
      len > height -> Enum.take(lines, -height)
      true -> List.duplicate("", height - len) ++ lines
    end
  end

  defp render_banner(nil, _width), do: []
  defp render_banner(banner, width), do: Components.WelcomeBanner.render(banner, width)

  defp render_entry(%mod{} = component, width), do: mod.render(component, width)

  defp render_entry({:user, text}, width) do
    WrapAnsi.wrap("> #{text}", width)
  end

  defp render_entry({:assistant, text, _}, width) do
    WrapAnsi.wrap(Safe.sanitize(text), width)
  end
end
