defmodule OctoPi.TUI.StdinFSM do
  @moduledoc """
  Escape-sequence assembly. Takes raw byte chunks from the stdin
  reader, pattern-matches them into complete sequences (CSI, OSC,
  SS3) + individual printable UTF-8 codepoints, and forwards each
  complete event to a subscriber as `{:stdin_event, binary}`.

  A 10ms flush timeout (configurable via `:flush_ms`) covers the
  two disambiguation cases the upstream port relies on:

    * A bare `\\e` at end of buffer could be either the Escape
      key or the start of an escape sequence arriving in pieces.
      We wait, and if nothing follows, flush it.
    * `\\e<char>` (Meta / Alt-prefix) can't be distinguished from
      a partial CSI/OSC until more bytes arrive. Same treatment.

  The timeout is driven by the GenServer's own `{:reply, state,
  ms}` return tuple — no `Process.send_after/3`, no timer refs.
  When the buffer is empty, we return `:infinity` so an idle FSM
  doesn't wake every 10ms for nothing.
  """

  use GenServer

  @default_flush_ms 10

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Feed a chunk of bytes into the FSM."
  @spec process(GenServer.server(), binary()) :: :ok
  def process(pid, bin) when is_binary(bin), do: GenServer.call(pid, {:process, bin})

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %{
      subscriber: Keyword.fetch!(opts, :subscriber),
      flush_ms: Keyword.get(opts, :flush_ms, @default_flush_ms),
      buffer: ""
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:process, chunk}, _from, state) do
    buffer = state.buffer <> chunk
    {events, remainder} = extract(buffer)
    Enum.each(events, &emit(state.subscriber, &1))
    {:reply, :ok, %{state | buffer: remainder}, flush_timeout(remainder, state.flush_ms)}
  end

  # Idle flush: an incomplete sequence has been sitting for
  # @flush_ms with no new bytes. Emit as-is and let the consumer
  # (KeyParser → `:unknown`) decide what to do.
  @impl true
  def handle_info(:timeout, %{buffer: ""} = state), do: {:noreply, state}

  def handle_info(:timeout, %{buffer: buf} = state) do
    emit(state.subscriber, buf)
    {:noreply, %{state | buffer: ""}}
  end

  # --- helpers ---

  defp flush_timeout("", _ms), do: :infinity
  defp flush_timeout(_buffer, ms), do: ms

  defp emit(subscriber, event), do: send(subscriber, {:stdin_event, event})

  # --- sequence extraction (multi-head pattern matching) ---

  # Returns {complete_events_in_order, remaining_buffer}.

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

  # Bare \e at end of buffer, or \e<char> where <char> isn't `[`,
  # `]`, or `O` — could be Escape, Alt-prefix, or the leading edge
  # of something more. Wait for the flush timeout to decide.
  defp extract(<<"\e", _::binary>> = buf), do: {[], buf}

  # UTF-8 codepoint — one grapheme cluster at a time. (Combining
  # marks etc. are out of scope for MVP; consumers work with whole
  # codepoints.)
  defp extract(<<cp::utf8, rest::binary>>) do
    {more, tail} = extract(rest)
    {[<<cp::utf8>> | more], tail}
  end

  # Invalid byte — drop it and continue.
  defp extract(<<_::8, rest::binary>>), do: extract(rest)

  # --- CSI extraction ---

  # `rest` is the body after `\e[`. The full buffer (with the
  # `\e[` prefix) is `buf`, used so we can splice the complete
  # sequence out in one binary_part call.
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

  # Scan for the first byte in 0x40..0x7E (CSI's final byte range).
  defp find_csi_final(<<>>, _idx), do: :incomplete

  defp find_csi_final(<<b::8, _::binary>>, idx) when b >= 0x40 and b <= 0x7E,
    do: {:found, idx}

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

  # Returns `{:found, body_len, terminator_len}` where body_len is
  # the count of bytes before the terminator and terminator_len is
  # 1 for BEL or 2 for ST. `:incomplete` if we haven't seen either.
  defp find_osc_end(<<>>, _idx), do: :incomplete
  defp find_osc_end(<<0x07, _::binary>>, idx), do: {:found, idx, 1}
  defp find_osc_end(<<"\e\\", _::binary>>, idx), do: {:found, idx, 2}
  defp find_osc_end(<<_::8, rest::binary>>, idx), do: find_osc_end(rest, idx + 1)
end
