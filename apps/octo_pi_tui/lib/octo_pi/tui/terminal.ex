defmodule OctoPi.TUI.Terminal do
  @moduledoc """
  GenServer that owns the TTY surface. Responsibilities:

    * Enter OTP 28's noshell raw mode on start; restore on terminate.
    * Listen for SIGWINCH via a gen_event handler on
      `erl_signal_server`; query actual dimensions via
      `:io.columns/0` / `:io.rows/0` and broadcast `{:resize, w, h}`
      through `OctoPi.TUI.Events`.
    * Spawn a linked reader that calls `:io.get_chars("", N)` in a
      loop and forwards each chunk back as a `{:stdin_chunk, bin}`
      message; Terminal feeds these into a `StdinFSM`, parses each
      cooked sequence with `KeyParser`, and broadcasts the parsed
      result as `{:key_event, parsed}` via `Events`.

  Tests inject mocks via opts so they don't flip the real tty:

    * `:skip_raw_mode` — don't enter/exit raw mode.
    * `:raw_mode_fn` — 1-arg fn `(:enter | :exit) -> :ok` that
      replaces the default `RawMode` calls. Useful when tests want
      to assert enter/exit were called.
    * `:skip_sigwinch` — don't register the SIGWINCH gen_event
      handler.
    * `:auto_start_reader` (default `true`) — when `false`, skips
      the stdin reader spawn. Tests inject chunks via
      `OctoPi.TUI.TerminalHelpers.simulate_stdin/2` instead.
    * `:dimensions` — `{width, height}` override for tests.

  Terminal dimensions are queried via `:io.columns/0` and
  `:io.rows/0` — no NIF required.

  Subscriber lifecycle drives activate/deactivate independently from
  the GenServer's own lifecycle:

    * `start_link/1` returns an *idle* Terminal — no raw mode, no
      reader, no SIGWINCH handler.
    * The first `open(pid)` *activates*: enters raw mode, registers
      SIGWINCH, spawns the reader, arms the kitty probe. Each open
      monitors its caller.
    * The last `close(pid)` (or the last holder's `:DOWN`) *deactivates*:
      runs cleanup (kitty disable, drain, raw-mode exit) and returns
      the Terminal to the idle state. The process stays alive and is
      ready to be re-opened.
    * `terminate/2` deactivates if currently active.

  Holders receive `{:key_event, parsed}`, `{:paste, content}`, and
  `{:resize, w, h}` messages directly. Multiple Terminal/Interactive
  pairs are isolated by construction — no global registry.

  Terminal owns the `%StdinFSM{}` directly: incoming reader chunks
  are fed through the FSM and narrowcast as cooked sequences. Raw
  chunks never leave the Terminal. Two GenServer-timeout deadlines
  coexist — the Kitty probe and the FSM flush — multiplexed via a
  `:deadlines` map keyed by kind; the next `:timeout` fires at the
  nearest deadline and re-arms whichever remains.
  """

  use GenServer

  alias OctoPi.TUI.Terminal.KeyParser
  alias OctoPi.TUI.Terminal.RawMode
  alias OctoPi.TUI.Terminal.SigwinchHandler
  alias OctoPi.TUI.Terminal.StdinFSM

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Write bytes to the Terminal's output. In production this is
  stdout via `IO.write/1`; tests inject a different write_fn via
  the `:write_fn` start_link opt to capture output.
  """
  @spec write(GenServer.server(), iodata()) :: :ok
  def write(pid, bytes), do: GenServer.call(pid, {:write, bytes})

  @doc false
  @spec info(GenServer.server()) :: map()
  def info(pid), do: GenServer.call(pid, :info)

  @doc "Open external editor with initial text; return {:ok, new_text} or {:error, reason}."
  @spec open_editor(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def open_editor(pid, initial_text), do: GenServer.call(pid, {:open_editor, initial_text}, :infinity)

  @doc """
  Open a handle on this Terminal. The first open activates the
  Terminal (raw mode, SIGWINCH, reader, kitty probe). The caller
  is monitored; an unexpected exit acts as an implicit `close/1`.
  """
  @spec open(GenServer.server()) :: :ok
  def open(pid), do: GenServer.call(pid, :open)

  @doc """
  Close the caller's handle. When the last handle is released, the
  Terminal tears itself down.
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
      raw_mode_fn: Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1),
      skip_raw_mode: Keyword.get(opts, :skip_raw_mode, false),
      skip_sigwinch: Keyword.get(opts, :skip_sigwinch, false),
      auto_start_reader: Keyword.get(opts, :auto_start_reader, true),
      reader_fn: Keyword.get(opts, :reader_fn, &default_reader/0),
      tty_fn: Keyword.get(opts, :tty_fn, &IO.write/1),
      write_fn: Keyword.get(opts, :write_fn, &IO.write/1),
      open_editor_fn: Keyword.get(opts, :open_editor_fn, &default_open_editor/1),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, 150),
      drain_idle_ms: Keyword.get(opts, :drain_idle_ms, 50),
      drain_timeout_ms: Keyword.get(opts, :drain_timeout_ms, 1000),
      flush_ms: Keyword.get(opts, :flush_ms, 10),
      reader_pid: nil,
      subscribers: %{},
      active: false,
      keyboard_mode: :none,
      stdin_buffer: "",
      paste_buffer: nil,
      deadlines: %{}
    }

    {:ok, state, next_timeout(state)}
  end

  # Both activate/1 and deactivate/1 are idempotent over the active
  # flag, so calling them while already in the target state is a
  # no-op. open and close drive these via subscriber refcount.

  defp activate(%{active: true} = state), do: state

  defp activate(%{skip_raw_mode: true} = state) do
    reader_pid = if state.auto_start_reader, do: spawn_reader(state.reader_fn)
    register_sigwinch(state)
    %{state | reader_pid: reader_pid, active: true}
  end

  defp activate(state) do
    state.raw_mode_fn.(:enter)

    # Spawn the reader after entering raw mode so it inherits the
    # updated group leader and `:io.get_chars/2` reads from the
    # live TTY rather than the noshell null device.
    reader_pid = if state.auto_start_reader, do: spawn_reader(state.reader_fn)
    register_sigwinch(state)
    tty_write(state, "\e[?2004h")
    tty_write(state, "\e[?u")

    state
    |> Map.put(:reader_pid, reader_pid)
    |> Map.put(:keyboard_mode, :probing)
    |> Map.put(:active, true)
    |> arm_deadline(:probe, System.monotonic_time(:millisecond) + state.probe_timeout_ms)
  end

  defp deactivate(%{active: false} = state), do: state

  defp deactivate(state) do
    if not state.skip_sigwinch do
      :gen_event.delete_handler(:erl_signal_server, SigwinchHandler, [])
    end

    if not state.skip_raw_mode do
      disable_keyboard_protocol(state)
      deadline = System.monotonic_time(:millisecond) + state.drain_timeout_ms
      drain_input(deadline, state.drain_idle_ms, 0)
      tty_write(state, "\e[?2004l")
      state.raw_mode_fn.(:exit)
    end

    kill_and_drain_reader(state.reader_pid)

    %{
      state
      | active: false,
        reader_pid: nil,
        keyboard_mode: :none,
        deadlines: %{},
        stdin_buffer: "",
        paste_buffer: nil
    }
  end

  defp kill_and_drain_reader(nil), do: :ok

  defp kill_and_drain_reader(pid) do
    Process.exit(pid, :kill)

    receive do
      {:EXIT, ^pid, _} -> :ok
    after
      100 -> :ok
    end
  end

  defp register_sigwinch(%{skip_sigwinch: true}), do: :ok
  defp register_sigwinch(_), do: :gen_event.add_handler(:erl_signal_server, SigwinchHandler, self())

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state, state, next_timeout(state)}

  def handle_call({:open_editor, initial_text}, _from, state) do
    result = do_open_editor(initial_text, state)
    {:reply, result, state, next_timeout(state)}
  end

  def handle_call({:write, bytes}, _from, state) do
    state.write_fn.(bytes)
    {:reply, :ok, state, next_timeout(state)}
  end

  def handle_call({:resize, w, h}, _from, state) do
    narrowcast(state, {:resize, w, h})
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
  def handle_info({:stdin_chunk, bin}, %{keyboard_mode: :probing} = state),
    do: handle_probing_stdin(extract_kitty_flags(bin), bin, state)

  def handle_info({:stdin_chunk, bin}, state) do
    state = process_chunk(bin, state)
    {:noreply, state, next_timeout(state)}
  end

  def handle_info({:signal, :sigwinch}, state) do
    case window_size() do
      {:ok, {w, h}} when w != state.width or h != state.height ->
        narrowcast(state, {:resize, w, h})
        {:noreply, %{state | width: w, height: h}, next_timeout(state)}

      _ ->
        {:noreply, state, next_timeout(state)}
    end
  end

  def handle_info(:timeout, state) do
    now = System.monotonic_time(:millisecond)
    {due, remaining} = pop_due(state.deadlines, now)
    state = %{state | deadlines: remaining}
    state = Enum.reduce(due, state, &fire_deadline/2)
    {:noreply, state, next_timeout(state)}
  end

  def handle_info({:EXIT, pid, reason}, %{reader_pid: pid} = state) do
    :telemetry.execute(
      [:octo_pi_tui, :terminal, :reader_down],
      %{},
      %{reason: reason}
    )

    {:stop, :normal, state}
  end

  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    state = state |> remove_subscriber_by_ref(ref) |> maybe_deactivate()
    {:noreply, state, next_timeout(state)}
  end

  def handle_info(_, state), do: {:noreply, state, next_timeout(state)}

  @impl true
  def terminate(reason, state) do
    :telemetry.execute(
      [:octo_pi_tui, :terminal, :terminate, :start],
      %{},
      %{reason: reason, keyboard_mode: state.keyboard_mode, reader_pid: state.reader_pid}
    )

    deactivate(state)

    :telemetry.execute([:octo_pi_tui, :terminal, :terminate, :stop], %{}, %{})
    :ok
  end

  # --- helpers ---

  defp do_open_editor(initial_text, state) do
    path = Path.join(System.tmp_dir!(), "octo_pi_editor_#{System.unique_integer([:positive])}.txt")

    try do
      File.write!(path, initial_text)
      state.raw_mode_fn.(:exit)

      result = state.open_editor_fn.(path)

      state.raw_mode_fn.(:enter)

      case result do
        :ok -> {:ok, File.read!(path)}
        {:error, reason} -> {:error, reason}
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

  defp drain_input(deadline_ms, idle_ms, round) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :telemetry.execute(
        [:octo_pi_tui, :terminal, :drain, :round],
        %{remaining_ms: remaining, round: round},
        %{outcome: :deadline}
      )

      :ok
    else
      receive do
        {:stdin_chunk, bin} ->
          :telemetry.execute(
            [:octo_pi_tui, :terminal, :drain, :round],
            %{remaining_ms: remaining, round: round, byte_count: byte_size(bin)},
            %{outcome: :consumed_chunk, bytes: bin}
          )

          drain_input(deadline_ms, idle_ms, round + 1)
      after
        min(remaining, idle_ms) ->
          :telemetry.execute(
            [:octo_pi_tui, :terminal, :drain, :round],
            %{remaining_ms: remaining, round: round},
            %{outcome: :idled}
          )

          :ok
      end
    end
  end

  defp default_raw_mode(:enter), do: RawMode.enter()
  defp default_raw_mode(:exit), do: RawMode.exit()

  defp disable_keyboard_protocol(%{keyboard_mode: :kitty} = state), do: tty_write(state, "\e[<0u")
  defp disable_keyboard_protocol(%{keyboard_mode: :modify_other_keys} = state), do: tty_write(state, "\e[>4m")
  defp disable_keyboard_protocol(_state), do: :ok

  # Kitty query response: \e[?<flags>u — starts with \e[? and ends with u.
  defp extract_kitty_flags(<<"\e[?", rest::binary>>) when byte_size(rest) >= 2 do
    inner_len = byte_size(rest) - 1
    if :binary.last(rest) == ?u, do: {:kitty, binary_part(rest, 0, inner_len)}, else: :not_kitty
  end

  defp extract_kitty_flags(_), do: :not_kitty

  defp handle_probing_stdin({:kitty, _flags}, _bin, state) do
    tty_write(state, "\e[>7u")
    state = state |> Map.put(:keyboard_mode, :kitty) |> disarm_deadline(:probe)
    {:noreply, state, next_timeout(state)}
  end

  defp handle_probing_stdin(:not_kitty, bin, state) do
    state = process_chunk(bin, state)
    {:noreply, state, next_timeout(state)}
  end

  defp process_chunk(bin, state) do
    :telemetry.execute([:octo_pi_tui, :stdin, :chunk], %{byte_count: byte_size(bin)}, %{bytes: bin})
    {sequences, tail} = StdinFSM.decode(state.stdin_buffer <> bin)
    state = Enum.reduce(sequences, state, &dispatch_seq(&2, &1))
    arm_or_disarm_flush(%{state | stdin_buffer: tail})
  end

  # Outside paste mode → parse + telemetry + broadcast as a key event.
  # `KeyParser` returns `:unknown` for sequences we don't recognize; those
  # are dropped (no consumer would know what to do with them). A spurious
  # paste-end marker outside paste mode is also dropped.
  defp dispatch_seq(%{paste_buffer: nil} = state, "\e[200~") do
    :telemetry.execute([:octo_pi_tui, :stdin, :sequence], %{}, %{seq: "\e[200~"})
    %{state | paste_buffer: ""}
  end

  defp dispatch_seq(%{paste_buffer: nil} = state, "\e[201~"), do: state

  defp dispatch_seq(%{paste_buffer: nil} = state, seq) do
    :telemetry.execute([:octo_pi_tui, :stdin, :sequence], %{}, %{seq: seq})
    parsed = KeyParser.parse(seq)
    :telemetry.execute([:octo_pi_tui, :key, :event], %{}, %{parsed: parsed, seq: seq})
    if parsed != :unknown, do: narrowcast(state, {:key_event, parsed})
    state
  end

  # Inside paste mode → end marker emits accumulated content as one
  # `:paste` broadcast; everything else accumulates raw bytes.
  defp dispatch_seq(%{paste_buffer: buf} = state, "\e[201~") do
    :telemetry.execute([:octo_pi_tui, :paste], %{byte_count: byte_size(buf)}, %{content: buf})
    narrowcast(state, {:paste, buf})
    %{state | paste_buffer: nil}
  end

  defp dispatch_seq(%{paste_buffer: buf} = state, seq), do: %{state | paste_buffer: buf <> seq}

  defp tty_write(state, bytes) do
    bin = IO.iodata_to_binary(bytes)

    :telemetry.execute(
      [:octo_pi_tui, :terminal, :tty_write],
      %{byte_count: byte_size(bin)},
      %{bytes: bin}
    )

    state.tty_fn.(bin)
  end

  defp arm_or_disarm_flush(%{stdin_buffer: ""} = state), do: disarm_deadline(state, :flush)
  defp arm_or_disarm_flush(state), do: arm_deadline(state, :flush, System.monotonic_time(:millisecond) + state.flush_ms)

  defp fire_deadline(:probe, %{keyboard_mode: :probing} = state) do
    tty_write(state, "\e[>4;2m")
    %{state | keyboard_mode: :modify_other_keys}
  end

  defp fire_deadline(:probe, state), do: state

  defp fire_deadline(:flush, %{stdin_buffer: ""} = state), do: state

  defp fire_deadline(:flush, %{stdin_buffer: buf} = state) do
    state = dispatch_seq(state, buf)
    %{state | stdin_buffer: ""}
  end

  defp arm_deadline(state, kind, abs_ms), do: %{state | deadlines: Map.put(state.deadlines, kind, abs_ms)}
  defp disarm_deadline(state, kind), do: %{state | deadlines: Map.delete(state.deadlines, kind)}

  defp next_timeout(%{deadlines: deadlines}) when map_size(deadlines) == 0, do: :infinity

  defp next_timeout(%{deadlines: deadlines}) do
    now = System.monotonic_time(:millisecond)
    earliest = deadlines |> Map.values() |> Enum.min()
    max(0, earliest - now)
  end

  defp pop_due(deadlines, now) do
    Enum.reduce(deadlines, {[], %{}}, fn {kind, ms}, {due, keep} ->
      if ms <= now, do: {[kind | due], keep}, else: {due, Map.put(keep, kind, ms)}
    end)
  end

  # Subscriber refcount drives activate/deactivate. The GenServer
  # itself stays alive across the cycle: a closed Terminal is just
  # an idle one waiting for the next open.
  defp maybe_deactivate(%{subscribers: subs} = state) when map_size(subs) == 0, do: deactivate(state)
  defp maybe_deactivate(state), do: state

  defp narrowcast(%{subscribers: subs}, msg) do
    for {pid, _ref} <- subs, do: send(pid, msg)
    :ok
  end

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

  defp window_size do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows() do
      {:ok, {cols, rows}}
    end
  end

  defp default_reader, do: :io.get_chars("", 256)

  defp spawn_reader(reader_fn) do
    parent = self()

    spawn_link(fn ->
      reader_fn
      |> reader_loop(parent)
      |> reader_exit(parent)
    end)
  end

  defp reader_loop(reader_fn, parent) do
    case reader_fn.() do
      :eof ->
        :eof
        reader_exit(:eof, parent)

      {:error, reason} ->
        reader_exit({:error, reason}, parent)

      data when is_list(data) or is_binary(data) ->
        bin = IO.iodata_to_binary(data)

        :telemetry.execute(
          [:octo_pi_tui, :reader, :read],
          %{byte_count: byte_size(bin)},
          %{bytes: bin}
        )

        send(parent, {:stdin_chunk, bin})
        reader_loop(reader_fn, parent)
    end
  end

  defp reader_exit(reason, parent) do
    :telemetry.execute(
      [:octo_pi_tui, :terminal, :reader_exit],
      %{},
      %{reason: reason, terminal: parent}
    )
  end
end
