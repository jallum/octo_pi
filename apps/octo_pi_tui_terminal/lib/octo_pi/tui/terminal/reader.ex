defmodule OctoPi.TUI.Terminal.Reader do
  @moduledoc """
  GenServer that owns the TTY surface for the duration of one
  reading session. Lifetime = "the TTY is in raw mode and we're
  reading from it."

  `init/1` enters raw mode, registers SIGWINCH, writes the
  bracketed-paste enable + kitty-keyboard probe, and spawn-links an
  inner *blocker* whose only job is to call `:io.get_chars/2` and
  forward each chunk back as a `{:tty_chunk, bin}` message. Reader
  filters the kitty-probe response itself; all other chunks (and
  resize events) are forwarded to the parent (Terminal) as
  `{:stdin_chunk, bin}` and `{:resize, w, h}`.

  `terminate/2` reverses the lot: kills the blocker, writes the
  appropriate kitty-disable based on negotiated mode, drains its own
  mailbox of pending TTY response bytes, writes the bracketed-paste
  disable, and exits raw mode.

  Test injection points are passed via opts: `:raw_mode_fn`,
  `:tty_fn`, `:reader_fn`, `:skip_raw_mode`, `:skip_sigwinch`,
  `:auto_start_reader`, plus the `:probe_timeout_ms`,
  `:drain_idle_ms`, `:drain_timeout_ms` knobs.
  """

  use GenServer

  alias OctoPi.TUI.Terminal.RawMode
  alias OctoPi.TUI.Terminal.SigwinchHandler

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      parent: Keyword.fetch!(opts, :parent),
      raw_mode_fn: Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1),
      skip_raw_mode: Keyword.get(opts, :skip_raw_mode, false),
      skip_sigwinch: Keyword.get(opts, :skip_sigwinch, false),
      auto_start_reader: Keyword.get(opts, :auto_start_reader, true),
      reader_fn: Keyword.get(opts, :reader_fn, &default_reader/0),
      tty_fn: Keyword.get(opts, :tty_fn, &IO.write/1),
      probe_timeout_ms: Keyword.get(opts, :probe_timeout_ms, 150),
      drain_idle_ms: Keyword.get(opts, :drain_idle_ms, 50),
      drain_timeout_ms: Keyword.get(opts, :drain_timeout_ms, 1000),
      blocker_pid: nil,
      keyboard_mode: :none
    }

    state = enter_tty(state)
    blocker = if state.auto_start_reader, do: spawn_blocker(self(), state.reader_fn)
    {:ok, %{state | blocker_pid: blocker}, probe_timeout(state)}
  end

  @impl true
  def handle_info({:tty_chunk, bin}, %{keyboard_mode: :probing} = state) do
    case extract_kitty_flags(bin) do
      {:kitty, _} ->
        tty_write(state, "\e[>7u")
        {:noreply, %{state | keyboard_mode: :kitty}}

      :not_kitty ->
        send(state.parent, {:stdin_chunk, bin})
        {:noreply, state, probe_timeout(state)}
    end
  end

  def handle_info({:tty_chunk, bin}, state) do
    send(state.parent, {:stdin_chunk, bin})
    {:noreply, state}
  end

  def handle_info(:timeout, %{keyboard_mode: :probing} = state) do
    tty_write(state, "\e[>4;2m")
    {:noreply, %{state | keyboard_mode: :modify_other_keys}}
  end

  def handle_info({:signal, :sigwinch}, state) do
    case window_size() do
      {:ok, {w, h}} -> send(state.parent, {:resize, w, h})
      _ -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:EXIT, pid, _reason}, %{blocker_pid: pid} = state), do: {:stop, :normal, state}

  def handle_info({:EXIT, _, reason}, state), do: {:stop, reason, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.blocker_pid && Process.alive?(state.blocker_pid) do
      Process.exit(state.blocker_pid, :kill)
    end

    leave_tty(state)
    :ok
  end

  # --- helpers ---

  defp enter_tty(%{skip_raw_mode: true} = state), do: state

  defp enter_tty(state) do
    state.raw_mode_fn.(:enter)

    if not state.skip_sigwinch do
      :gen_event.add_handler(:erl_signal_server, SigwinchHandler, self())
    end

    tty_write(state, "\e[?2004h")
    tty_write(state, "\e[?u")
    %{state | keyboard_mode: :probing}
  end

  defp leave_tty(%{skip_raw_mode: true}), do: :ok

  defp leave_tty(state) do
    if not state.skip_sigwinch do
      :gen_event.delete_handler(:erl_signal_server, SigwinchHandler, [])
    end

    disable_keyboard_protocol(state)
    drain_input(System.monotonic_time(:millisecond) + state.drain_timeout_ms, state.drain_idle_ms)
    tty_write(state, "\e[?2004l")
    tty_write(state, "\e[?25h")
    state.raw_mode_fn.(:exit)
    :ok
  end

  defp disable_keyboard_protocol(%{keyboard_mode: :kitty} = state), do: tty_write(state, "\e[<0u")
  defp disable_keyboard_protocol(%{keyboard_mode: :modify_other_keys} = state), do: tty_write(state, "\e[>4m")
  defp disable_keyboard_protocol(_), do: :ok

  # Drain TTY responses to the disable sequences out of our mailbox
  # before flipping the kernel back to cooked.
  defp drain_input(deadline_ms, idle_ms) do
    remaining = deadline_ms - System.monotonic_time(:millisecond)

    if remaining > 0 do
      receive do
        {:tty_chunk, _} -> drain_input(deadline_ms, idle_ms)
      after
        min(remaining, idle_ms) -> :ok
      end
    end
  end

  defp probe_timeout(%{keyboard_mode: :probing, probe_timeout_ms: ms}), do: ms
  defp probe_timeout(_), do: :infinity

  defp tty_write(state, bytes) do
    bin = IO.iodata_to_binary(bytes)
    :telemetry.execute([:octo_pi_tui, :terminal, :tty_write], %{byte_count: byte_size(bin)}, %{bytes: bin})
    state.tty_fn.(bin)
  end

  # Kitty query response: \e[?<flags>u — starts with \e[? and ends with u.
  defp extract_kitty_flags(<<"\e[?", rest::binary>>) when byte_size(rest) >= 2 do
    inner_len = byte_size(rest) - 1
    if :binary.last(rest) == ?u, do: {:kitty, binary_part(rest, 0, inner_len)}, else: :not_kitty
  end

  defp extract_kitty_flags(_), do: :not_kitty

  defp window_size do
    with {:ok, cols} <- :io.columns(), {:ok, rows} <- :io.rows(), do: {:ok, {cols, rows}}
  end

  defp default_raw_mode(:enter), do: RawMode.enter()
  defp default_raw_mode(:exit), do: RawMode.exit()

  defp default_reader, do: :io.get_chars("", 256)

  defp spawn_blocker(parent, reader_fn) do
    spawn_link(fn -> blocker_loop(parent, reader_fn) end)
  end

  defp blocker_loop(parent, reader_fn) do
    case reader_fn.() do
      data when is_list(data) or is_binary(data) ->
        bin = IO.iodata_to_binary(data)
        :telemetry.execute([:octo_pi_tui, :terminal, :read_bytes], %{byte_count: byte_size(bin)}, %{bytes: bin})
        send(parent, {:tty_chunk, bin})
        blocker_loop(parent, reader_fn)

      reason ->
        :telemetry.execute([:octo_pi_tui, :terminal, :reader_exit], %{}, %{reason: reason, terminal: parent})
    end
  end
end
