defmodule OctoPi.TUI.StdinFSM do
  @moduledoc """
  Stateless escape-sequence decoder. Pattern-matches a binary into a
  list of complete cooked sequences (CSI, OSC, SS3, DCS, APC,
  alt-prefix) plus individual UTF-8 codepoints, and returns whatever
  unresolved tail is left over for the caller to feed back in.

  The caller (Terminal) owns the buffer and decides what to do with
  the tail — typically: prepend it to the next chunk, and after some
  idle period emit the tail as-is to disambiguate a bare `\\e` from
  the start of a longer sequence.

  `\\e<char>` where char isn't `[`, `]`, `O`, `P`, or `_` is treated
  as a complete alt-prefix meta sequence and emitted immediately.

  ## Divergence from upstream: bracketed paste as data events

  Upstream pi-mono's StdinBuffer exposes a separate `paste` event
  whose payload is the content between `\\e[200~` and `\\e[201~`
  and suppresses `data` events during a paste. This module does not
  replicate that: paste markers and content come back through the
  same channel. Consumers that need paste atomicity collect events
  between the two markers.
  """

  @doc """
  Decode `bin` into `{events, tail}`. `events` is the list of
  complete cooked sequences (in order); `tail` is whatever
  unresolved bytes remain — typically a partial escape sequence
  awaiting more data.
  """
  @spec decode(binary()) :: {[binary()], binary()}
  def decode(bin) when is_binary(bin), do: extract(bin)

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

  # Bare \e at end of buffer — wait for more bytes.
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
