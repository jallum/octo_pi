defmodule OctoPi.TUI.StdinFSM do
  @moduledoc """
  Escape-sequence assembly. Takes raw byte chunks, pattern-matches
  them into complete sequences (CSI, OSC, SS3, DCS, APC, alt-prefix)
  + individual printable UTF-8 codepoints, and returns a list of
  cooked sequences plus the next flush deadline.

  The module is a pure struct + pure functions; the caller (Terminal)
  owns the buffer state, dispatches events, and arms the flush
  timeout.

  A 10ms flush timeout (configurable via `:flush_ms`) handles one
  disambiguation case: a bare `\\e` at end of buffer could be
  either the Escape key or the start of an escape sequence
  arriving in pieces. After the timeout the caller should call
  `flush/1` to emit whatever is still buffered.

  `\\e<char>` where char isn't `[`, `]`, `O`, `P`, or `_` is treated
  as a complete alt-prefix meta sequence and emitted immediately.

  ## Divergence from upstream: bracketed paste as data events

  Upstream pi-mono's StdinBuffer exposes a separate `paste` event
  whose payload is the content between `\\e[200~` and `\\e[201~`
  and suppresses `data` events during a paste. StdinFSM does not
  replicate that: paste markers and content are emitted through the
  same channel. Consumers that need paste atomicity collect events
  between the two markers.

  ## GenServer wrapper

  A thin GenServer wrapper is retained as a transitional shim for
  callers that still own the FSM as a child process. It delegates
  to the pure API and is scheduled for removal once Terminal owns
  the FSM directly (see opi-445.2 / opi-445.4).
  """

  @default_flush_ms 10

  defstruct buffer: "", flush_ms: @default_flush_ms

  @type t :: %__MODULE__{buffer: binary(), flush_ms: pos_integer()}
  @type process_result :: {t(), [binary()], non_neg_integer() | :infinity}

  use GenServer

  # --- pure API + GenServer wrapper ---

  @doc "Build a new FSM state."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{flush_ms: Keyword.get(opts, :flush_ms, @default_flush_ms)}
  end

  @doc """
  Feed a chunk of bytes into the FSM. Returns `{state, events,
  next_timeout_ms | :infinity}` for a `%StdinFSM{}` state, or `:ok`
  for the GenServer wrapper.
  """
  @spec process(t(), binary()) :: process_result()
  def process(%__MODULE__{} = state, bin) when is_binary(bin) do
    buffer = state.buffer <> bin
    {events, remainder} = extract(buffer)
    {%{state | buffer: remainder}, events, flush_timeout(remainder, state.flush_ms)}
  end

  @spec process(GenServer.server(), binary()) :: :ok
  def process(server, bin) when is_binary(bin), do: GenServer.call(server, {:process, bin})

  @doc """
  Flush any buffered content as a single sequence. For a struct
  state returns `{state, events}`; for the GenServer wrapper returns
  `events`.
  """
  @spec flush(t()) :: {t(), [binary()]}
  def flush(%__MODULE__{buffer: ""} = state), do: {state, []}
  def flush(%__MODULE__{buffer: buf} = state), do: {%{state | buffer: ""}, [buf]}

  @spec flush(GenServer.server()) :: [binary()]
  def flush(server), do: GenServer.call(server, :flush)

  @doc "Discard any buffered content without emitting."
  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = state), do: %{state | buffer: ""}

  @spec clear(GenServer.server()) :: :ok
  def clear(server), do: GenServer.call(server, :clear)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Return the current buffer contents (for testing)."
  @spec get_buffer(GenServer.server()) :: binary()
  def get_buffer(server), do: GenServer.call(server, :get_buffer)

  @impl true
  def init(opts) do
    fsm = new(flush_ms: Keyword.get(opts, :flush_ms, @default_flush_ms))
    {:ok, %{fsm: fsm, subscriber: Keyword.fetch!(opts, :subscriber)}}
  end

  @impl true
  def handle_call({:process, bin}, _from, %{fsm: fsm} = state) do
    {fsm, events, timeout} = process(fsm, bin)
    Enum.each(events, &emit(state.subscriber, &1))
    {:reply, :ok, %{state | fsm: fsm}, timeout}
  end

  def handle_call(:flush, _from, %{fsm: fsm} = state) do
    {fsm, events} = flush(fsm)
    Enum.each(events, &emit(state.subscriber, &1))
    {:reply, events, %{state | fsm: fsm}, :infinity}
  end

  def handle_call(:clear, _from, %{fsm: fsm} = state) do
    {:reply, :ok, %{state | fsm: clear(fsm)}, :infinity}
  end

  def handle_call(:get_buffer, _from, %{fsm: fsm} = state) do
    {:reply, fsm.buffer, state, flush_timeout(fsm.buffer, fsm.flush_ms)}
  end

  @impl true
  def handle_info(:timeout, %{fsm: fsm} = state) do
    {fsm, events} = flush(fsm)
    Enum.each(events, &emit(state.subscriber, &1))
    {:noreply, %{state | fsm: fsm}}
  end

  defp emit(subscriber, event) do
    :telemetry.execute([:octo_pi_tui, :stdin, :sequence], %{}, %{seq: event})
    send(subscriber, {:stdin_event, event})
  end

  # --- helpers ---

  defp flush_timeout("", _ms), do: :infinity
  defp flush_timeout(_buffer, ms), do: ms

  # --- sequence extraction (multi-head pattern matching) ---

  defp extract(""), do: {[], ""}

  # CSI: \e[<params><intermediate><final 0x40-0x7E>
  defp extract(<<"\e[", rest::binary>> = buf), do: extract_csi(rest, buf)

  # OSC: \e]<any>... terminated by BEL (0x07) or ST (\e\)
  defp extract(<<"\e]", rest::binary>> = buf), do: extract_osc(rest, buf)

  # SS3: \eO<char> — always a 3-byte sequence when complete.
  defp extract(<<"\eO", b::8, rest::binary>>) do
    {more, tail} = extract(rest)
    {[<<"\eO", b>> | more], tail}
  end

  # SS3 prefix alone at end of buffer — wait for the final byte.
  defp extract(<<"\eO">>), do: {[], "\eO"}

  # DCS: \eP<any>... terminated by ST (\e\)
  defp extract(<<"\eP", rest::binary>> = buf), do: extract_dcs_apc(rest, buf)

  # APC: \e_<any>... terminated by ST (\e\)
  defp extract(<<"\e_", rest::binary>> = buf), do: extract_dcs_apc(rest, buf)

  # Alt-prefix: \e followed by a byte that isn't [, ], O, P, or _.
  # Emitted immediately as a 2-byte meta sequence.
  defp extract(<<"\e", b::8, rest::binary>>) do
    {more, tail} = extract(rest)
    {[<<"\e", b>> | more], tail}
  end

  # Bare \e at end of buffer — wait for the flush timeout.
  defp extract(<<"\e">>), do: {[], "\e"}

  # UTF-8 codepoint.
  defp extract(<<cp::utf8, rest::binary>>) do
    {more, tail} = extract(rest)
    {[<<cp::utf8>> | more], tail}
  end

  # Invalid byte — drop it and continue.
  defp extract(<<_::8, rest::binary>>), do: extract(rest)

  # --- CSI extraction ---

  # Old-style X11 mouse: \e[M + 3 bytes (button, x, y).
  defp extract_csi(<<"M", rest::binary>>, _buf) when byte_size(rest) >= 3 do
    <<b1::8, b2::8, b3::8, remaining::binary>> = rest
    seq = <<"\e[M", b1, b2, b3>>
    {more, tail} = extract(remaining)
    {[seq | more], tail}
  end

  defp extract_csi(<<"M", _::binary>>, buf), do: {[], buf}

  defp extract_csi(rest, buf) do
    case find_csi_final(rest, 0) do
      :incomplete ->
        {[], buf}

      {:found, idx} ->
        seq_len = 2 + idx + 1
        seq = binary_part(buf, 0, seq_len)
        remaining = binary_part(buf, seq_len, byte_size(buf) - seq_len)
        {more, tail} = extract(remaining)
        {[seq | more], tail}
    end
  end

  defp find_csi_final(<<>>, _idx), do: :incomplete

  defp find_csi_final(<<b::8, _::binary>>, idx) when b >= 0x40 and b <= 0x7E, do: {:found, idx}

  defp find_csi_final(<<_::8, rest::binary>>, idx), do: find_csi_final(rest, idx + 1)

  # --- OSC extraction ---

  defp extract_osc(rest, buf) do
    case find_osc_end(rest, 0) do
      :incomplete ->
        {[], buf}

      {:found, body_len, terminator_len} ->
        seq_len = 2 + body_len + terminator_len
        seq = binary_part(buf, 0, seq_len)
        remaining = binary_part(buf, seq_len, byte_size(buf) - seq_len)
        {more, tail} = extract(remaining)
        {[seq | more], tail}
    end
  end

  defp find_osc_end(<<>>, _idx), do: :incomplete
  defp find_osc_end(<<0x07, _::binary>>, idx), do: {:found, idx, 1}
  defp find_osc_end(<<"\e\\", _::binary>>, idx), do: {:found, idx, 2}
  defp find_osc_end(<<_::8, rest::binary>>, idx), do: find_osc_end(rest, idx + 1)

  # --- DCS / APC extraction ---
  # Both use only ST (\e\) as terminator; prefix is already consumed (2 bytes).

  defp extract_dcs_apc(rest, buf) do
    case find_st_end(rest, 0) do
      :incomplete ->
        {[], buf}

      {:found, body_len} ->
        seq_len = 2 + body_len + 2
        seq = binary_part(buf, 0, seq_len)
        remaining = binary_part(buf, seq_len, byte_size(buf) - seq_len)
        {more, tail} = extract(remaining)
        {[seq | more], tail}
    end
  end

  defp find_st_end(<<>>, _idx), do: :incomplete
  defp find_st_end(<<"\e\\", _::binary>>, idx), do: {:found, idx}
  defp find_st_end(<<_::8, rest::binary>>, idx), do: find_st_end(rest, idx + 1)
end
