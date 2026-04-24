defmodule OctoPi.TUI.Safe do
  @moduledoc false

  @doc """
  Strip dangerous ANSI escape sequences from untrusted text,
  keeping only SGR (Select Graphic Rendition) codes that set
  colors and text attributes.
  """
  @spec sanitize(String.t()) :: String.t()
  def sanitize(text), do: do_sanitize(text, "")

  # CSI sequence: \e[ ... <final byte>
  defp do_sanitize(<<"\e[", rest::binary>>, acc) do
    {params, final, remaining} = consume_csi(rest)

    if final == ?m do
      do_sanitize(remaining, acc <> "\e[" <> params <> "m")
    else
      do_sanitize(remaining, acc)
    end
  end

  # OSC: \e] ... (BEL | ST)
  defp do_sanitize(<<"\e]", rest::binary>>, acc),
    do: do_sanitize(skip_osc(rest), acc)

  # DCS: \eP ... ST
  defp do_sanitize(<<"\eP", rest::binary>>, acc),
    do: do_sanitize(skip_st_terminated(rest), acc)

  # APC: \e_ ... ST
  defp do_sanitize(<<"\e_", rest::binary>>, acc),
    do: do_sanitize(skip_st_terminated(rest), acc)

  # PM: \e^ ... ST
  defp do_sanitize(<<"\e^", rest::binary>>, acc),
    do: do_sanitize(skip_st_terminated(rest), acc)

  # SS3: \eO + one byte
  defp do_sanitize(<<"\eO", _::8, rest::binary>>, acc),
    do: do_sanitize(rest, acc)

  # Bare ESC followed by other character — strip the pair
  defp do_sanitize(<<"\e", _::8, rest::binary>>, acc),
    do: do_sanitize(rest, acc)

  # Trailing bare ESC
  defp do_sanitize(<<"\e">>, acc), do: acc

  # Normal character
  defp do_sanitize(<<c::utf8, rest::binary>>, acc),
    do: do_sanitize(rest, acc <> <<c::utf8>>)

  defp do_sanitize(<<>>, acc), do: acc

  # Consume CSI params + final byte. Final is 0x40..0x7E.
  defp consume_csi(<<>>), do: {"", 0, ""}

  defp consume_csi(<<b::8, rest::binary>>) when b >= 0x40 and b <= 0x7E,
    do: {"", b, rest}

  defp consume_csi(<<b::8, rest::binary>>) do
    {params, final, remaining} = consume_csi(rest)
    {<<b>> <> params, final, remaining}
  end

  # Skip until BEL or ST (\e\\)
  defp skip_osc(<<>>), do: ""
  defp skip_osc(<<0x07, rest::binary>>), do: rest
  defp skip_osc(<<"\e\\", rest::binary>>), do: rest
  defp skip_osc(<<_::8, rest::binary>>), do: skip_osc(rest)

  # Skip until ST (\e\\)
  defp skip_st_terminated(<<>>), do: ""
  defp skip_st_terminated(<<"\e\\", rest::binary>>), do: rest
  defp skip_st_terminated(<<_::8, rest::binary>>), do: skip_st_terminated(rest)
end
