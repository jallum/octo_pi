defmodule OctoPi.AI.SanitizeUnicode do
  @moduledoc """
  Strips invalid UTF-8 bytes from binaries before JSON serialization.

  The TypeScript upstream (`sanitize-unicode.ts`) removes unpaired UTF-16
  surrogates (0xD800–0xDFFF), which are invalid in JSON. Elixir strings are
  UTF-8, not UTF-16, so surrogates cannot be represented directly, but
  binaries from external sources may contain invalid byte sequences that
  would cause `Jason.encode!/1` to raise. The effect is semantically
  equivalent: both prevent serialization errors caused by malformed text.

  Applied at request-serialization time only (in provider request builders),
  not during message construction.
  """

  @spec sanitize(binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    if String.valid?(text), do: text, else: strip_invalid(text, <<>>)
  end

  defp strip_invalid(<<>>, acc), do: acc

  defp strip_invalid(<<c::utf8, rest::binary>>, acc), do: strip_invalid(rest, <<acc::binary, c::utf8>>)

  defp strip_invalid(<<_byte, rest::binary>>, acc), do: strip_invalid(rest, acc)
end
