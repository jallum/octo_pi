defmodule OctoPi.TUI.Terminal do
  @moduledoc """
  GenServer that fronts a TTY session and dispatches cooked events
  to subscribers. The TTY surface itself — raw mode, the read loop,
  the kitty probe, SIGWINCH, the bracketed-paste enable/disable —
  lives in `OctoPi.TUI.Terminal.Reader`. Terminal is its parent and
  receives `{:stdin_chunk, bin}` and `{:resize, w, h}` messages from
  the Reader.

  Subscriber lifecycle drives Reader's lifetime independently from
  the GenServer's own:

    * `start_link/1` returns an *idle* Terminal — no Reader spawned,
      no TTY held.
    * The first `open(pid)` *activates*: starts a Reader, which
      enters raw mode, registers SIGWINCH, spawns the inner blocker,
      and probes kitty.
    * The last `close(pid)` (or last holder's `:DOWN`) *deactivates*:
      stops the Reader (which runs its own `terminate/2` to write
      the kitty disable, drain TTY responses, exit raw mode) and
      returns Terminal to idle. The Terminal process stays alive,
      ready to be re-opened.
    * `terminate/2` deactivates if currently active.

  Holders receive `{:hid_event, struct, mono_us}` messages, where `struct` is
  one of `%Key{}`, `%Paste{}`, or `%Terminal.Resize{}` and `mono_us` is
  `System.monotonic_time(:microsecond)` at narrowcast send (used by
  receivers to compute key arrival → handled latency telemetry).
  Multiple Terminal/Interactive pairs are isolated by construction — no
  global registry.

  Terminal owns the `StdinFSM` decode buffer + the bracketed-paste
  accumulator. The only deadline it tracks is the FSM flush — a
  bare `\\e` at end of buffer waits `flush_ms` for disambiguating
  bytes before being emitted as the Escape key.

  Test injection points (most flow through to Reader): `:tty_fn`,
  `:write_fn`, `:raw_mode_fn`, `:skip_raw_mode`, `:skip_sigwinch`,
  `:auto_start_reader`, `:reader_fn`, `:probe_timeout_ms`,
  `:drain_idle_ms`, `:drain_timeout_ms`, `:flush_ms`,
  `:open_editor_fn`, `:dimensions`, `:name`.
  """

  use GenServer

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Paste
  alias OctoPi.TUI.Terminal.KeyParser
  alias OctoPi.TUI.Terminal.Reader
  alias OctoPi.TUI.Terminal.Resize
  alias OctoPi.TUI.Terminal.StdinFSM

  @reader_opt_keys [
    :raw_mode_fn,
    :skip_raw_mode,
    :skip_sigwinch,
    :auto_start_reader,
    :reader_fn,
    :tty_fn,
    :probe_timeout_ms,
    :drain_idle_ms,
    :drain_timeout_ms
  ]

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Write bytes to the Terminal's output. In production this is
  stdout via `IO.write/1`; tests inject a different `write_fn` via
  the start_link opt to capture output.
  """
  @spec write(GenServer.server(), iodata()) :: :ok
  def write(pid, bytes), do: GenServer.call(pid, {:write, bytes})

  @doc """
  Toggle the OSC 9;4 terminal progress indicator (a taskbar-progress
  hint understood by ConEmu / Windows Terminal / iTerm2). `true`
  sets indeterminate state; `false` clears. Terminals that don't
  recognize the sequence ignore it. Mirrors upstream's
  `terminal.setProgress` call during compaction.
  """
  @spec set_progress(GenServer.server(), boolean()) :: :ok
  def set_progress(pid, true), do: write(pid, "\e]9;4;3;\a")
  def set_progress(pid, false), do: write(pid, "\e]9;4;0;\a")

  @doc false
  @spec info(GenServer.server()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Open external editor with initial text; return {:ok, new_text} or {:error, reason}."
  @spec open_editor(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def open_editor(pid, initial_text), do: GenServer.call(pid, {:open_editor, initial_text}, :infinity)

  @doc """
  Open a handle on this Terminal. The first open activates the
  Terminal (spawns a Reader, enters raw mode, etc). The caller is
  monitored; an unexpected exit acts as an implicit `close/1`.
  """
  @spec open(GenServer.server()) :: :ok
  def open(pid), do: GenServer.call(pid, :open)

  @doc """
  Close the caller's handle. When the last handle is released, the
  Terminal deactivates (stops its Reader) and returns to the idle
  state.
  """
  @spec close(GenServer.server()) :: :ok
  def close(pid), do: GenServer.call(pid, :close)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    {w, h} = Keyword.get(opts, :dimensions, {80, 24})

    state = %{
      width: w,
      height: h,
      write_fn: Keyword.get(opts, :write_fn, &IO.write/1),
      open_editor_fn: Keyword.get(opts, :open_editor_fn, &default_open_editor/1),
      flush_ms: Keyword.get(opts, :flush_ms, 10),
      reader_opts: Keyword.take(opts, @reader_opt_keys),
      reader_pid: nil,
      subscribers: %{},
      stdin_buffer: "",
      paste_buffer: nil,
      flush_at: nil
    }

    {:ok, state, next_timeout(state)}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state, state, next_timeout(state)}

  def handle_call({:open_editor, initial_text}, _from, state) do
    {result, state} = do_open_editor(initial_text, state)
    {:reply, result, state, next_timeout(state)}
  end

  def handle_call({:write, bytes}, _from, state) do
    state.write_fn.(bytes)
    {:reply, :ok, state, next_timeout(state)}
  end

  def handle_call({:resize, w, h}, _from, state) do
    narrowcast(state, {:hid_event, %Resize{width: w, height: h}})
    {:reply, :ok, %{state | width: w, height: h}, next_timeout(state)}
  end

  def handle_call(:open, {caller, _tag}, state) do
    state = state |> activate() |> add_subscriber(caller)
    {:reply, :ok, state, next_timeout(state)}
  end

  def handle_call(:close, {caller, _tag}, state) do
    state = state |> remove_subscriber(caller) |> maybe_deactivate()
    {:reply, :ok, state, next_timeout(state)}
  end

  @impl true
  def handle_info({:stdin_chunk, bin}, state) do
    state = process_chunk(bin, state)
    {:noreply, state, next_timeout(state)}
  end

  def handle_info({:resize, w, h}, state) do
    narrowcast(state, {:hid_event, %Resize{width: w, height: h}})
    {:noreply, %{state | width: w, height: h}, next_timeout(state)}
  end

  def handle_info(:timeout, state) do
    state = if flush_due?(state), do: flush_pending(state), else: state
    {:noreply, state, next_timeout(state)}
  end

  # Reader exited spontaneously (its blocker hit EOF/error, or it
  # crashed) — TTY is gone. Stop ourselves.
  def handle_info({:EXIT, pid, _reason}, %{reader_pid: pid} = state), do: {:stop, :normal, %{state | reader_pid: nil}}

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = state |> remove_subscriber_by_ref(ref) |> maybe_deactivate()
    {:noreply, state, next_timeout(state)}
  end

  def handle_info(_, state), do: {:noreply, state, next_timeout(state)}

  @impl true
  def terminate(_reason, state) do
    deactivate(state)
    :ok
  end

  # --- activation lifecycle ---

  defp activate(%{reader_pid: pid} = state) when is_pid(pid), do: state

  defp activate(state) do
    {:ok, reader} = Reader.start_link([{:parent, self()} | state.reader_opts])
    %{state | reader_pid: reader}
  end

  defp deactivate(%{reader_pid: nil} = state), do: %{state | stdin_buffer: "", paste_buffer: nil, flush_at: nil}

  defp deactivate(%{reader_pid: pid} = state) when is_pid(pid) do
    GenServer.stop(pid, :normal, :infinity)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      100 -> :ok
    end

    %{state | reader_pid: nil, stdin_buffer: "", paste_buffer: nil, flush_at: nil}
  end

  defp maybe_deactivate(%{subscribers: subs} = state) when map_size(subs) == 0, do: deactivate(state)
  defp maybe_deactivate(state), do: state

  # --- editor session ---

  # Cycle the Reader so the editor runs in cooked mode.
  defp do_open_editor(initial_text, state) do
    path = Path.join(System.tmp_dir!(), "octo_pi_editor_#{System.unique_integer([:positive])}.txt")

    try do
      File.write!(path, initial_text)
      was_active = is_pid(state.reader_pid)
      state = if was_active, do: deactivate(state), else: state
      result = state.open_editor_fn.(path)
      state = if was_active, do: activate(state), else: state

      case result do
        :ok -> {{:ok, File.read!(path)}, state}
        {:error, reason} -> {{:error, reason}, state}
      end
    after
      File.rm(path)
    end
  end

  defp default_open_editor(path) do
    editor = System.get_env("VISUAL") || System.get_env("EDITOR")

    if editor do
      System.cmd(editor, [path])
      :ok
    else
      {:error, :no_editor}
    end
  end

  # --- chunk processing ---

  defp process_chunk(bin, state) do
    :telemetry.execute([:octo_pi_tui, :stdin, :chunk], %{byte_count: byte_size(bin)}, %{bytes: bin})
    {sequences, tail} = StdinFSM.decode(state.stdin_buffer <> bin)
    state = Enum.reduce(sequences, state, &dispatch_seq(&2, &1))
    arm_or_disarm_flush(%{state | stdin_buffer: tail})
  end

  # Outside paste mode: parse, fire telemetry, narrowcast.
  # `KeyParser` returns `:unknown` for sequences we don't recognize;
  # those are dropped. A spurious paste-end marker outside paste mode
  # is also dropped.
  defp dispatch_seq(%{paste_buffer: nil} = state, "\e[200~") do
    :telemetry.execute([:octo_pi_tui, :stdin, :sequence], %{}, %{seq: "\e[200~"})
    %{state | paste_buffer: ""}
  end

  defp dispatch_seq(%{paste_buffer: nil} = state, "\e[201~"), do: state

  defp dispatch_seq(%{paste_buffer: nil} = state, seq) do
    :telemetry.execute([:octo_pi_tui, :stdin, :sequence], %{}, %{seq: seq})
    parsed = KeyParser.parse(seq)
    :telemetry.execute([:octo_pi_tui, :key, :event], %{}, %{parsed: parsed, seq: seq})
    maybe_narrowcast_key(state, parsed)
    state
  end

  # Inside paste mode: end marker emits accumulated content as one
  # paste event; everything else accumulates raw bytes.
  defp dispatch_seq(%{paste_buffer: buf} = state, "\e[201~") do
    :telemetry.execute([:octo_pi_tui, :paste], %{byte_count: byte_size(buf)}, %{content: buf})
    narrowcast(state, {:hid_event, %Paste{content: buf}})
    %{state | paste_buffer: nil}
  end

  defp dispatch_seq(%{paste_buffer: buf} = state, seq), do: %{state | paste_buffer: buf <> seq}

  defp maybe_narrowcast_key(state, %Key{} = key), do: narrowcast(state, {:hid_event, key})
  defp maybe_narrowcast_key(_state, :unknown), do: :ok

  # --- flush deadline ---

  defp arm_or_disarm_flush(%{stdin_buffer: ""} = state), do: %{state | flush_at: nil}
  defp arm_or_disarm_flush(state), do: %{state | flush_at: System.monotonic_time(:millisecond) + state.flush_ms}

  defp flush_due?(%{flush_at: nil}), do: false
  defp flush_due?(%{flush_at: at}), do: at <= System.monotonic_time(:millisecond)

  defp flush_pending(%{stdin_buffer: ""} = state), do: %{state | flush_at: nil}

  defp flush_pending(%{stdin_buffer: buf} = state) do
    state |> dispatch_seq(buf) |> Map.merge(%{stdin_buffer: "", flush_at: nil})
  end

  defp next_timeout(%{flush_at: nil}), do: :infinity

  defp next_timeout(%{flush_at: at}) do
    now = System.monotonic_time(:millisecond)
    max(0, at - now)
  end

  # --- subscribers ---

  defp narrowcast(%{subscribers: subs}, msg) do
    stamped = stamp_hid_event(msg)
    for {pid, _ref} <- subs, do: send(pid, stamped)
    :ok
  end

  # Tag :hid_event tuples with the monotonic time at narrowcast send so
  # receivers can compute key arrival → handled latency. Other message
  # shapes pass through unchanged.
  defp stamp_hid_event({:hid_event, payload}) do
    {:hid_event, payload, System.monotonic_time(:microsecond)}
  end

  defp stamp_hid_event(other), do: other

  defp add_subscriber(%{subscribers: subs} = state, pid) do
    case Map.fetch(subs, pid) do
      {:ok, _ref} -> state
      :error -> %{state | subscribers: Map.put(subs, pid, Process.monitor(pid))}
    end
  end

  defp remove_subscriber(%{subscribers: subs} = state, pid) do
    case Map.pop(subs, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: rest}
    end
  end

  defp remove_subscriber_by_ref(%{subscribers: subs} = state, ref) do
    case Enum.find(subs, fn {_pid, r} -> r == ref end) do
      nil -> state
      {pid, _} -> %{state | subscribers: Map.delete(subs, pid)}
    end
  end
end
