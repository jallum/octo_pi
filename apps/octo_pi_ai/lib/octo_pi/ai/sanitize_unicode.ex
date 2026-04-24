defmodule OctoPi.AI.SanitizeUnicode do
  @moduledoc """
  Strips invalid UTF-8 bytes from binaries.

  JavaScript strings are UTF-16 and can contain unpaired surrogates
  (0xD800–0xDFFF), which cause JSON serialization errors in many APIs.
  Elixir strings are UTF-8 by definition so surrogates can't exist,
  but binaries received from external sources may contain invalid
  byte sequences. This module normalizes them.

  Ported from `sanitize-unicode.ts`.
  """

  @spec sanitize(binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    if String.valid?(text), do: text, else: strip_invalid(text, <<>>)
  end

  defp strip_invalid(<<>>, acc), do: acc

  defp strip_invalid(<<c::utf8, rest::binary>>, acc),
    do: strip_invalid(rest, <<acc::binary, c::utf8>>)

  defp strip_invalid(<<_byte, rest::binary>>, acc),
    do: strip_invalid(rest, acc)
end
