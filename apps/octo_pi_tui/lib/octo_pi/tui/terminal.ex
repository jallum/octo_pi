defmodule OctoPi.TUI.Terminal do
  @moduledoc """
  GenServer that owns the TTY surface. Responsibilities:

    * Enter OTP 28's noshell raw mode on start; restore on terminate.
    * Register as the SIGWINCH handler; broadcast `{:resize, w, h}`
      events through `OctoPi.TUI.Events` whenever the window size
      changes.
    * Spawn a linked reader that calls `:io.get_chars("", N)` in a
      loop and forwards each chunk back as a `{:stdin_chunk, bin}`
      message, which Terminal rebroadcasts via `Events`.

  Tests inject mocks via opts so they don't flip the real tty:

    * `:skip_raw_mode` — don't enter/exit raw mode.
    * `:raw_mode_fn` — 1-arg fn `(:enter | :exit) -> :ok` that
      replaces the default `RawMode` calls. Useful when tests want
      to assert enter/exit were called.
    * `:skip_sigwinch` — don't register `:os.set_signal/2`.
    * `:auto_start_reader` (default `true`) — when `false`, skips
      the stdin reader spawn. Tests feed chunks with
      `feed_chunk/2` instead.
    * `:dimensions` — `{width, height}` override for tests.

  `Events` is a Registry keyed on topic atoms. Subscribers register
  via `Registry.register(OctoPi.TUI.Events, :stdin_chunk, nil)` or
  `:resize`; Terminal dispatches via
  `Registry.dispatch(Events, topic, fn entries -> ... end)`.
  """

  use GenServer

  alias OctoPi.TUI.Events
  alias OctoPi.TUI.RawMode

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Snapshot the Terminal state (for tests + debugging)."
  @spec state(GenServer.server()) :: map()
  def state(pid), do: GenServer.call(pid, :state)

  @doc """
  Feed a chunk of bytes into the Terminal as if they had arrived on
  stdin. Used by the reader loop in production, and by tests that
  want to exercise the broadcast path without real I/O.
  """
  @spec feed_chunk(GenServer.server(), binary()) :: :ok
  def feed_chunk(pid, bin) when is_binary(bin), do: GenServer.call(pid, {:feed_chunk, bin})

  @doc """
  Simulate a window resize with explicit dimensions. Used by tests
  (and by the production SIGWINCH handler after reading new dims).
  """
  @spec simulate_resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def simulate_resize(pid, width, height),
    do: GenServer.call(pid, {:resize, width, height})

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    raw_mode_fn = Keyword.get(opts, :raw_mode_fn, &default_raw_mode/1)
    skip_raw_mode = Keyword.get(opts, :skip_raw_mode, false)
    skip_sigwinch = Keyword.get(opts, :skip_sigwinch, false)
    auto_start_reader = Keyword.get(opts, :auto_start_reader, true)
    {w, h} = Keyword.get(opts, :dimensions, {80, 24})

    unless skip_raw_mode, do: raw_mode_fn.(:enter)
    unless skip_sigwinch, do: :os.set_signal(:sigwinch, :handle)

    state = %{
      width: w,
      height: h,
      raw_mode_fn: raw_mode_fn,
      skip_raw_mode: skip_raw_mode,
      reader_pid: nil
    }

    state =
      case auto_start_reader do
        true -> %{state | reader_pid: spawn_reader()}
        false -> state
      end

    {:ok, state}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:feed_chunk, bin}, _from, state) do
    broadcast(:stdin_chunk, {:stdin_chunk, bin})
    {:reply, :ok, state}
  end

  def handle_call({:resize, w, h}, _from, state) do
    broadcast(:resize, {:resize, w, h})
    {:reply, :ok, %{state | width: w, height: h}}
  end

  @impl true
  def handle_info({:stdin_chunk, bin}, state) do
    broadcast(:stdin_chunk, {:stdin_chunk, bin})
    {:noreply, state}
  end

  def handle_info({:signal, :sigwinch}, state) do
    w = term_cols(state.width)
    h = term_rows(state.height)
    broadcast(:resize, {:resize, w, h})
    {:noreply, %{state | width: w, height: h}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{skip_raw_mode: true}), do: :ok

  def terminate(_reason, %{raw_mode_fn: fun}) do
    fun.(:exit)
    :ok
  end

  # --- helpers ---

  defp default_raw_mode(:enter), do: RawMode.enter()
  defp default_raw_mode(:exit), do: RawMode.exit()

  defp broadcast(topic, msg) do
    Registry.dispatch(Events, topic, fn subscribers ->
      for {pid, _} <- subscribers, do: send(pid, msg)
    end)
  end

  defp spawn_reader do
    parent = self()
    spawn_link(fn -> reader_loop(parent) end)
  end

  defp reader_loop(parent) do
    case :io.get_chars("", 256) do
      :eof ->
        :ok

      {:error, _} ->
        :ok

      data when is_list(data) or is_binary(data) ->
        send(parent, {:stdin_chunk, IO.iodata_to_binary(data)})
        reader_loop(parent)
    end
  end

  defp term_cols(fallback) do
    case :io.columns() do
      {:ok, n} -> n
      _ -> fallback
    end
  end

  defp term_rows(fallback) do
    case :io.rows() do
      {:ok, n} -> n
      _ -> fallback
    end
  end
end
