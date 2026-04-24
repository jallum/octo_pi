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

  alias OctoPi.TUI.{Components, Events, Key, KeyParser, Renderer, StdinFSM, Terminal, Viewport, WrapAnsi}

  @type transcript_entry ::
          {:user, String.t()}
          | {:assistant, String.t(), :streaming | :done}

  @type t :: %__MODULE__{
          session: pid() | nil,
          input: Components.Input.t(),
          transcript: [transcript_entry()],
          width: pos_integer(),
          height: pos_integer(),
          exit: boolean(),
          paste_buffer: String.t() | nil
        }

  defstruct session: nil,
            input: %Components.Input{},
            transcript: [],
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
    {w, h} = Keyword.get(opts, :dimensions, {80, 24})
    write_fn = Keyword.get(opts, :write_fn, &IO.write/1)

    session = start_agent_session(opts)
    {:ok, terminal} = start_terminal(opts, write_fn)
    {:ok, fsm} = StdinFSM.start_link(subscriber: self())
    {:ok, renderer} = Renderer.start_link(width: w, height: h)

    {:ok, _} = Registry.register(Events, :stdin_chunk, nil)
    {:ok, _} = Registry.register(Events, :resize, nil)
    OctoPi.Agent.subscribe(session, self(), :async)

    state = %__MODULE__{session: session, width: w, height: h}
    render_frame(state, renderer, terminal)

    loop(state, fsm, renderer, terminal)

    shutdown(terminal, fsm, renderer)
    :ok
  end

  defp default_raw_mode(:enter), do: OctoPi.TUI.RawMode.enter()
  defp default_raw_mode(:exit), do: OctoPi.TUI.RawMode.exit()

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
    tools = Keyword.get_lazy(opts, :tools, fn -> OctoPi.Coder.default_tools(cwd) end)

    system_prompt =
      Keyword.get_lazy(opts, :system_prompt, fn ->
        OctoPi.Coder.SystemPrompt.render(cwd: cwd, tools: tools)
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
    lines = render(state)
    {:ok, bytes} = Renderer.render(renderer, lines)
    cursor_seq = cursor_position(state, lines)

    payload =
      case {bytes, cursor_seq} do
        {"", ""} -> ""
        {b, c} -> b <> c
      end

    if payload != "", do: Terminal.write(terminal, payload)
    :ok
  end

  # CSI H positions the hardware cursor at (row, col) — both
  # 1-indexed. Row = index of the Input's line in the rendered
  # frame + 1. Col = 1 + the Input's grapheme cursor offset
  # (plus the `"> "` prefix width if the input ever sprouts
  # one; for MVP it's plain).
  defp cursor_position(%__MODULE__{input: %{cursor: c} = input}, lines) do
    input_lines = Components.Input.render(input, 1_000_000)
    input_row = length(lines) - length(input_lines) + 1
    "\e[#{input_row};#{c + 1}H"
  end

  # Shut down children in reverse start order. Terminal goes last
  # because its `terminate/2` restores the tty.
  defp shutdown(terminal, fsm, renderer) do
    for pid <- [renderer, fsm, terminal], Process.alive?(pid) do
      GenServer.stop(pid, :normal)
    end

    :ok
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

  # Ctrl+C always exits immediately.
  def handle_event(state, {:key, %Key{key: ?c, modifiers: [:ctrl]}}),
    do: %{state | exit: true}

  # Escape: clear input if non-empty, exit if already empty.
  def handle_event(%{input: %{value: ""}} = state, {:key, %Key{key: :escape}}),
    do: %{state | exit: true}

  def handle_event(%{input: input} = state, {:key, %Key{key: :escape}}),
    do: %{state | input: %{input | value: "", cursor: 0}}

  # Enter submits the prompt.
  def handle_event(%{input: input, session: session} = state, {:key, %Key{key: :enter}}) do
    case Components.Input.handle_key(input, %Key{key: :enter}) do
      {new_input, [{:submit, value}]} when value != "" ->
        if session, do: OctoPi.Agent.prompt(session, value)

        %{
          state
          | input: %{new_input | value: "", cursor: 0},
            transcript: state.transcript ++ [{:user, value}]
        }

      _ ->
        state
    end
  end

  # Other named keys route to the Input component.
  def handle_event(%{input: input} = state, {:key, %Key{} = key}) do
    case Components.Input.handle_key(input, key) do
      {new_input, _events} -> %{state | input: new_input}
      new_input -> %{state | input: new_input}
    end
  end

  # Paste buffering: accumulate chars between markers, flush atomically.
  def handle_event(state, :paste_start),
    do: %{state | paste_buffer: ""}

  def handle_event(%{paste_buffer: buf} = state, {:char, c}) when is_binary(buf),
    do: %{state | paste_buffer: buf <> c}

  def handle_event(%{paste_buffer: buf, input: input} = state, :paste_end) when is_binary(buf),
    do: %{state | input: Components.Input.paste(input, buf), paste_buffer: nil}

  def handle_event(state, :paste_end),
    do: %{state | paste_buffer: nil}

  # Printable chars insert into the Input.
  def handle_event(%{input: input} = state, {:char, c}),
    do: %{state | input: Components.Input.insert(input, c)}

  # Agent events drive the transcript.
  def handle_event(state, {:octo_pi_agent_event, event}),
    do: %{state | transcript: update_transcript(state.transcript, event)}

  # Resize.
  def handle_event(state, {:resize, w, h}), do: %{state | width: w, height: h}

  # Unknown — no-op.
  def handle_event(state, _), do: state

  # --- transcript updates ---

  # MessageUpdate streams text into the last assistant entry;
  # MessageEnd finalizes it. Other events are ignored for MVP
  # rendering (they show up in telemetry but don't affect the
  # transcript text we paint).

  defp update_transcript(transcript, %{
         __struct__: OctoPi.Agent.Event.MessageUpdate,
         partial: partial
       }),
       do: apply_partial(transcript, partial)

  defp update_transcript(transcript, %{__struct__: OctoPi.Agent.Event.MessageEnd, message: msg}),
    do: finalize_assistant(transcript, msg)

  defp update_transcript(transcript, _), do: transcript

  defp apply_partial(transcript, partial) do
    text = extract_text(partial)

    case List.last(transcript) do
      {:assistant, _, :streaming} ->
        List.replace_at(transcript, -1, {:assistant, text, :streaming})

      _ ->
        transcript ++ [{:assistant, text, :streaming}]
    end
  end

  defp finalize_assistant(transcript, msg) do
    text = extract_text(msg)

    case List.last(transcript) do
      {:assistant, _, :streaming} ->
        List.replace_at(transcript, -1, {:assistant, text, :done})

      _ ->
        transcript ++ [{:assistant, text, :done}]
    end
  end

  defp extract_text(%{content: content}) when is_list(content) do
    content
    |> Enum.filter(&match?(%OctoPi.AI.Content.Text{}, &1))
    |> Enum.map_join("", & &1.text)
  end

  defp extract_text(_), do: ""

  # --- rendering helpers (pure) ---

  @doc """
  Render the current state into a list of lines ready for the
  renderer. Transcript entries are word-wrapped at `width`, then
  the whole frame is windowed to `height` via the Viewport.
  """
  @spec render(t()) :: [binary()]
  def render(%{transcript: transcript, input: input, width: width, height: height}) do
    transcript_lines = Enum.flat_map(transcript, &render_entry(&1, width))
    input_lines = Components.Input.render(input, width)
    all = transcript_lines ++ [""] ++ input_lines
    Viewport.window(all, height)
  end

  defp render_entry({:user, text}, width), do: WrapAnsi.wrap("> #{text}", width)
  defp render_entry({:assistant, text, _}, width), do: WrapAnsi.wrap(text, width)
end
