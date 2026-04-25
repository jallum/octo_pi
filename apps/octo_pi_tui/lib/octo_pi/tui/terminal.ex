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
      message, which Terminal rebroadcasts via `Events`.

  Tests inject mocks via opts so they don't flip the real tty:

    * `:skip_raw_mode` — don't enter/exit raw mode.
    * `:raw_mode_fn` — 1-arg fn `(:enter | :exit) -> :ok` that
      replaces the default `RawMode` calls. Useful when tests want
      to assert enter/exit were called.
    * `:skip_sigwinch` — don't register the SIGWINCH gen_event
      handler.
    * `:auto_start_reader` (default `true`) — when `false`, skips
      the stdin reader spawn. Tests feed chunks with
      `feed_chunk/2` instead.
    * `:dimensions` — `{width, height}` override for tests.

  Terminal dimensions are queried via `:io.columns/0` and
  `:io.rows/0` — no NIF required.

  `Events` is a Registry keyed on `{topic, scope}` tuples.
  Subscribers register via
  `Registry.register(Events, {:stdin_chunk, terminal_pid}, nil)`;
  Terminal dispatches via
  `Registry.dispatch(Events, {:stdin_chunk, scope}, fn entries -> ... end)`.
  The scope defaults to `self()` (the Terminal pid), isolating
  concurrent Interactive sessions from each other's events.
  """

  use GenServer

  alias OctoPi.TUI.Events
  alias OctoPi.TUI.RawMode
  alias OctoPi.TUI.SigwinchHandler

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

  @doc false
  @spec feed_chunk(GenServer.server(), binary()) :: :ok
  def feed_chunk(pid, bin) when is_binary(bin), do: GenServer.call(pid, {:feed_chunk, bin})

  @doc false
  @spec simulate_resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def simulate_resize(pid, width, height), do: GenServer.call(pid, {:resize, width, height})

  @doc "Inject a raw stdin chunk as if it arrived from the reader (for tests)."
  @spec simulate_stdin(GenServer.server(), binary()) :: :ok
  def simulate_stdin(pid, bin) when is_binary(bin) do
    send(pid, {:stdin_chunk, bin})
    :ok
  end

  @doc "Returns true if the Kitty keyboard protocol is currently active."
  @spec kitty_protocol_active?(GenServer.server()) :: boolean()
  def kitty_protocol_active?(pid), do: GenServer.call(pid, :kitty_protocol_active?)

  @doc "Suspend: exit raw mode, send SIGTSTP, re-enter raw mode on resume."
  @spec suspend(GenServer.server()) :: :ok
  def suspend(pid), do: GenServer.call(pid, :suspend, :infinity)

  @doc "Open external editor with initial text; return {:ok, new_text} or {:error, reason}."
  @spec open_editor(GenServer.server(), String.t()) :: {:ok, String.t()} | {:error, atom()}
  def open_editor(pid, initial_text), do: GenServer.call(pid, {:open_editor, initial_text}, :infinity)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    raw_mode_fn = Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1)
    skip_raw_mode = Keyword.get(opts, :skip_raw_mode, false)
    skip_sigwinch = Keyword.get(opts, :skip_sigwinch, false)
    auto_start_reader = Keyword.get(opts, :auto_start_reader, true)
    {w, h} = Keyword.get(opts, :dimensions, {80, 24})
    probe_timeout_ms = Keyword.get(opts, :probe_timeout_ms, 150)
    drain_idle_ms = Keyword.get(opts, :drain_idle_ms, 50)
    drain_timeout_ms = Keyword.get(opts, :drain_timeout_ms, 1000)
    send_sigtstp_fn = Keyword.get(opts, :send_sigtstp_fn, &default_send_sigtstp/0)
    open_editor_fn = Keyword.get(opts, :open_editor_fn, &default_open_editor/1)

    write_fn = Keyword.get(opts, :write_fn, &IO.write/1)
    tty_fn = Keyword.get(opts, :tty_fn, &IO.write/1)

    if not skip_sigwinch do
      :gen_event.add_handler(:erl_signal_server, SigwinchHandler, self())
    end

    reader_fn = Keyword.get(opts, :reader_fn, &default_reader/0)
    reader_pid = if auto_start_reader, do: spawn_reader(reader_fn)

    base_state = %{
      width: w,
      height: h,
      raw_mode_fn: raw_mode_fn,
      skip_raw_mode: skip_raw_mode,
      skip_sigwinch: skip_sigwinch,
      tty_fn: tty_fn,
      reader_pid: reader_pid,
      write_fn: write_fn,
      scope: self(),
      probe_timeout_ms: probe_timeout_ms,
      drain_idle_ms: drain_idle_ms,
      drain_timeout_ms: drain_timeout_ms,
      send_sigtstp_fn: send_sigtstp_fn,
      open_editor_fn: open_editor_fn,
      keyboard_mode: :none,
      probe_start: nil
    }

    if skip_raw_mode do
      {:ok, base_state}
    else
      raw_mode_fn.(:enter)
      tty_fn.("\e[?2004h")
      tty_fn.("\e[?u")
      probe_start = System.monotonic_time(:millisecond)
      state = %{base_state | keyboard_mode: :probing, probe_start: probe_start}
      {:ok, state, probe_timeout_ms}
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, state, state}

  def handle_call(:kitty_protocol_active?, _from, state) do
    {:reply, state.keyboard_mode == :kitty, state}
  end

  def handle_call(:suspend, _from, state) do
    state.raw_mode_fn.(:exit)
    state.send_sigtstp_fn.()
    state.raw_mode_fn.(:enter)
    {:reply, :ok, state}
  end

  def handle_call({:open_editor, initial_text}, _from, state) do
    result = do_open_editor(initial_text, state)
    {:reply, result, state}
  end

  def handle_call({:feed_chunk, bin}, _from, state) do
    broadcast(state, :stdin_chunk, {:stdin_chunk, bin})
    {:reply, :ok, state}
  end

  def handle_call({:write, bytes}, _from, state) do
    state.write_fn.(bytes)
    {:reply, :ok, state}
  end

  def handle_call({:resize, w, h}, _from, state) do
    broadcast(state, :resize, {:resize, w, h})
    {:reply, :ok, %{state | width: w, height: h}}
  end

  @impl true
  def handle_info({:stdin_chunk, bin}, %{keyboard_mode: :probing} = state) do
    handle_probing_stdin(extract_kitty_flags(bin), bin, state)
  end

  def handle_info({:stdin_chunk, bin}, state) do
    :telemetry.execute([:octo_pi_tui, :stdin, :chunk], %{byte_count: byte_size(bin)}, %{bytes: bin})
    broadcast(state, :stdin_chunk, {:stdin_chunk, bin})
    {:noreply, state}
  end

  def handle_info({:signal, :sigwinch}, state) do
    case window_size() do
      {:ok, {w, h}} when w != state.width or h != state.height ->
        broadcast(state, :resize, {:resize, w, h})
        {:noreply, %{state | width: w, height: h}}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(:timeout, %{keyboard_mode: :probing} = state) do
    state.tty_fn.("\e[>4;2m")
    {:noreply, %{state | keyboard_mode: :modify_other_keys, probe_start: nil}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if not state.skip_sigwinch do
      :gen_event.delete_handler(:erl_signal_server, SigwinchHandler, [])
    end

    if not state.skip_raw_mode do
      disable_keyboard_protocol(state)
      deadline = System.monotonic_time(:millisecond) + state.drain_timeout_ms
      drain_input(deadline, state.drain_idle_ms)
      state.tty_fn.("\e[?2004l")
      state.raw_mode_fn.(:exit)
    end

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

  defp default_send_sigtstp do
    if match?({:unix, _}, :os.type()) do
      pid_str = List.to_string(:os.getpid())
      System.cmd("kill", ["-TSTP", pid_str])
    end

    :ok
  end

  defp drain_input(deadline_ms, idle_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      :ok
    else
      receive do
        {:stdin_chunk, _} -> drain_input(deadline_ms, idle_ms)
      after
        min(remaining, idle_ms) -> :ok
      end
    end
  end

  defp default_raw_mode(:enter), do: RawMode.enter()
  defp default_raw_mode(:exit), do: RawMode.exit()

  defp disable_keyboard_protocol(%{keyboard_mode: :kitty} = state) do
    state.tty_fn.("\e[<0u")
  end

  defp disable_keyboard_protocol(%{keyboard_mode: :modify_other_keys} = state) do
    state.tty_fn.("\e[>4m")
  end

  defp disable_keyboard_protocol(_state), do: :ok

  # Kitty query response: \e[?<flags>u — starts with \e[? and ends with u.
  defp extract_kitty_flags(<<"\e[?", rest::binary>>) when byte_size(rest) >= 2 do
    inner_len = byte_size(rest) - 1
    if :binary.last(rest) == ?u, do: {:kitty, binary_part(rest, 0, inner_len)}, else: :not_kitty
  end

  defp extract_kitty_flags(_), do: :not_kitty

  defp handle_probing_stdin({:kitty, _flags}, _bin, state) do
    state.tty_fn.("\e[>7u")
    {:noreply, %{state | keyboard_mode: :kitty, probe_start: nil}}
  end

  defp handle_probing_stdin(:not_kitty, bin, state) do
    :telemetry.execute([:octo_pi_tui, :stdin, :chunk], %{byte_count: byte_size(bin)}, %{bytes: bin})
    broadcast(state, :stdin_chunk, {:stdin_chunk, bin})
    elapsed = System.monotonic_time(:millisecond) - state.probe_start
    {:noreply, state, max(0, state.probe_timeout_ms - elapsed)}
  end

  defp broadcast(state, topic, msg) do
    Registry.dispatch(Events, {topic, state.scope}, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, msg)
    end)
  end

  defp window_size do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows() do
      {:ok, {cols, rows}}
    end
  end

  defp default_reader, do: :io.get_chars("", 256)

  defp spawn_reader(reader_fn) do
    parent = self()
    spawn_link(fn -> reader_loop(parent, reader_fn) end)
  end

  defp reader_loop(parent, reader_fn) do
    case reader_fn.() do
      :eof ->
        reader_exit(:eof, parent)

      {:error, reason} ->
        reader_exit({:error, reason}, parent)

      data when is_list(data) or is_binary(data) ->
        send(parent, {:stdin_chunk, IO.iodata_to_binary(data)})
        reader_loop(parent, reader_fn)
    end
  end

  defp reader_exit(reason, parent) do
    require Logger

    Logger.warning("Terminal stdin reader exited: #{inspect(reason)}")

    :telemetry.execute(
      [:octo_pi_tui, :terminal, :reader_exit],
      %{},
      %{reason: reason, terminal: parent}
    )
  end
end
