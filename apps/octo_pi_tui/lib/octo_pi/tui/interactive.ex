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
    Viewport,
    WrapAnsi
  }

  alias Components.{AssistantMessage, Footer, ToolExecution, UserMessage}
  alias OctoPi.Coder

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
          paste_buffer: String.t() | nil
        }

  defstruct session: nil,
            input: %Components.Input{},
            transcript: [],
            footer: %Footer{},
            footer_data: nil,
            theme: nil,
            width: 80,
            height: 24,
            exit: false,
            paste_buffer: nil

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
    {:ok, renderer} = Renderer.start_link(width: w, height: h)
    {:ok, footer_data} = FooterData.start_link(cwd: cwd)

    {:ok, _} = Registry.register(Events, {:stdin_chunk, terminal}, nil)
    {:ok, _} = Registry.register(Events, {:resize, terminal}, nil)
    OctoPi.Agent.subscribe(session, self(), :async)

    theme = Theme.load_builtin(:dark, Theme.detect_color_mode())

    footer = %Footer{
      cwd: cwd,
      model_id: model.id,
      context_window: model.context_window,
      git_branch: FooterData.get_git_branch(footer_data)
    }

    state = %__MODULE__{
      session: session,
      input: %Components.Input{width: w},
      width: w,
      height: h,
      theme: theme,
      footer: footer,
      footer_data: footer_data
    }

    render_frame(state, renderer, terminal)

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

      {:EXIT, _pid, _reason} ->
        loop(%{state | exit: true}, fsm, renderer, terminal)
    end
  end

  defp advance(new_state, fsm, renderer, terminal) do
    render_frame(new_state, renderer, terminal)
    loop(new_state, fsm, renderer, terminal)
  end

  defp render_frame(state, renderer, terminal) do
    input_lines = Components.Input.render(state.input, state.width)
    lines = render(state, input_lines)
    {:ok, bytes} = Renderer.render(renderer, lines)
    cursor_seq = cursor_position(state, input_lines, lines)

    payload =
      case {bytes, cursor_seq} do
        {"", ""} -> ""
        {b, c} -> b <> c
      end

    if payload != "", do: Terminal.write(terminal, payload)
    :ok
  end

  defp cursor_position(
         %__MODULE__{input: input, width: width, footer: footer},
         input_lines,
         lines
       ) do
    {crow, ccol} = Components.Input.cursor_rc(input, width)
    footer_height = length(Footer.render(footer, width))
    input_start = length(lines) - footer_height - length(input_lines) + 1
    "\e[#{input_start + crow};#{ccol + 1}H"
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

  def handle_event(%{input: %{value: ""}} = state, {:key, %Key{key: :escape}}),
    do: %{state | exit: true}

  def handle_event(%{input: input} = state, {:key, %Key{key: :escape}}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  def handle_event(%{input: input, session: session} = state, {:key, %Key{key: :enter}}) do
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

  def handle_event(%{input: input} = state, {:key, %Key{} = key}) do
    case Components.Input.handle_key(input, key) do
      {new_input, _events} -> %{state | input: new_input}
      new_input -> %{state | input: new_input}
    end
  end

  def handle_event(state, :paste_start),
    do: %{state | paste_buffer: ""}

  def handle_event(%{paste_buffer: buf} = state, {:char, c}) when is_binary(buf),
    do: %{state | paste_buffer: buf <> c}

  def handle_event(%{paste_buffer: buf, input: input} = state, :paste_end) when is_binary(buf),
    do: %{state | input: Components.Input.paste(input, buf), paste_buffer: nil}

  def handle_event(state, :paste_end),
    do: %{state | paste_buffer: nil}

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
    do: %{state | width: w, height: h, input: %{state.input | width: w}}

  def handle_event(state, _), do: state

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
    transcript
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find(fn
      {%AssistantMessage{}, _idx} -> true
      _ -> false
    end)
    |> case do
      {msg, idx} -> {idx, msg}
      nil -> nil
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
  Render the current state into a list of lines ready for the
  renderer. Transcript entries are rendered via their component
  render/2, then the frame is windowed to `height` via the Viewport.
  """
  @spec render(t()) :: [binary()]
  def render(%{input: input, width: width} = state) do
    render(state, Components.Input.render(input, width))
  end

  @spec render(t(), [binary()]) :: [binary()]
  def render(%{transcript: transcript, footer: footer, width: width, height: height}, input_lines) do
    footer_lines = Footer.render(footer, width)
    content_height = max(1, height - length(footer_lines))

    transcript_lines = Enum.flat_map(transcript, &render_entry(&1, width))
    all = transcript_lines ++ [""] ++ input_lines
    Viewport.window(all, content_height) ++ footer_lines
  end

  defp render_entry(%mod{} = component, width), do: mod.render(component, width)

  defp render_entry({:user, text}, width) do
    WrapAnsi.wrap("> #{text}", width)
  end

  defp render_entry({:assistant, text, _}, width) do
    WrapAnsi.wrap(Safe.sanitize(text), width)
  end
end
