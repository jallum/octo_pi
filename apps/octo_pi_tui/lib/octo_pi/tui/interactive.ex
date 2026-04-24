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

  alias OctoPi.TUI.{Components, Key}

  @type transcript_entry ::
          {:user, String.t()}
          | {:assistant, String.t(), :streaming | :done}

  @type t :: %__MODULE__{
          session: pid() | nil,
          input: Components.Input.t(),
          transcript: [transcript_entry()],
          width: pos_integer(),
          height: pos_integer(),
          exit: boolean()
        }

  defstruct session: nil,
            input: %Components.Input{},
            transcript: [],
            width: 80,
            height: 24,
            exit: false

  @doc """
  Entry point for the CLI. Not fully wired yet — the full main
  loop (Terminal + FSM + Renderer + event pump) is a follow-up
  task. For now, accepts opts but returns immediately with a
  "not implemented" message so the CLI's dispatch path is
  testable.
  """
  @spec run(keyword()) :: :ok
  def run(_opts) do
    IO.puts(:stderr, "[octo_pi_tui] interactive mode MVP stub — full wiring lands with follow-up")
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

  # Ctrl+C always exits immediately (no double-press for MVP).
  def handle_event(state, {:key, %Key{key: ?c, modifiers: [:ctrl]}}),
    do: %{state | exit: true}

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

  # Printable chars insert into the Input.
  def handle_event(%{input: input} = state, {:char, c}),
    do: %{state | input: Components.Input.insert(input, c)}

  # Paste markers — MVP doesn't do bracketed paste semantics yet.
  def handle_event(state, :paste_start), do: state
  def handle_event(state, :paste_end), do: state

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
  renderer. Transcript lines come first, then a blank, then the
  Input component.
  """
  @spec render(t()) :: [binary()]
  def render(%{transcript: transcript, input: input, width: width}) do
    transcript_lines = Enum.flat_map(transcript, &render_entry(&1, width))

    transcript_lines ++ [""] ++ Components.Input.render(input, width)
  end

  defp render_entry({:user, text}, width), do: wrap_line("> #{text}", width)

  defp render_entry({:assistant, text, _}, width), do: wrap_line(text, width)

  defp wrap_line(line, _width) when is_binary(line), do: String.split(line, "\n")
end
