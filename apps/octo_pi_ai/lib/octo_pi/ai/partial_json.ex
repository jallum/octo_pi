defmodule OctoPi.AI.PartialJson do
  @moduledoc """
  JSON repair and best-effort parsing for streaming tool-call arguments.

  Ported from `tmp/pi-mono/packages/ai/src/utils/json-parse.ts`. Two
  public entry points:

  - `parse_with_repair/1` — for fully-formed JSON frames that may
    contain minor corruption (raw control chars inside strings,
    invalid escape sequences). Returns `{:ok, term}` or `{:error, _}`.

  - `parse_streaming/1` — for `input_json_delta` accumulators where
    the JSON is truncated mid-flight. Always returns a map — even if
    the input is empty, a primitive, an array, or unrepairable.

  See `docs/port-map/anthropic.md` §4.
  """

  defguardp is_hex(c)
            when (c >= ?0 and c <= ?9) or
                   (c >= ?a and c <= ?f) or
                   (c >= ?A and c <= ?F)

  # Note: `u` is NOT listed here; \uXXXX is validated separately because
  # it requires 4 hex digits to follow. `\u` with non-hex should still
  # double the backslash.
  defguardp is_valid_escape(c)
            when c in [?", ?\\, ?/, ?b, ?f, ?n, ?r, ?t]

  @doc """
  Parse JSON, repairing raw control chars and invalid escapes if the
  first parse fails. Returns `{:ok, term} | {:error, reason}`.

  If the repair pass produces an identical string (nothing to fix),
  returns the original decoder error unchanged.
  """
  @spec parse_with_repair(binary()) :: {:ok, term()} | {:error, term()}
  def parse_with_repair(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, _} = ok ->
        ok

      {:error, _} = err ->
        repaired = repair(json)

        if repaired == json do
          err
        else
          Jason.decode(repaired)
        end
    end
  end

  @doc """
  Parse a (possibly truncated) JSON string and always return a map.

  Strategy:
    1. `parse_with_repair/1`; if it yields a map, return it.
    2. Close unterminated strings, drop trailing `,` or `:`, balance
       brackets; retry parse; if it yields a map, return it.
    3. Apply `repair/1` then step 2 again; if map, return it.
    4. Fall back to `%{}`.
  """
  @spec parse_streaming(binary() | nil) :: map()
  def parse_streaming(nil), do: %{}
  def parse_streaming(""), do: %{}

  def parse_streaming(json) when is_binary(json) do
    if String.trim(json) == "" do
      %{}
    else
      with :miss <- try_direct(json),
           :miss <- try_partial(json),
           :miss <- try_partial(repair(json)) do
        %{}
      else
        map when is_map(map) -> map
      end
    end
  end

  @spec try_direct(binary()) :: map() | :miss
  defp try_direct(json) do
    case parse_with_repair(json) do
      {:ok, map} when is_map(map) -> map
      _ -> :miss
    end
  end

  @spec try_partial(binary()) :: map() | :miss
  defp try_partial(json) do
    closed = close_partial(json)

    case Jason.decode(closed) do
      {:ok, map} when is_map(map) -> map
      _ -> :miss
    end
  end

  @doc """
  Repair JSON string literals: escape raw control characters inside
  strings, double-backslash any invalid escape sequences. Outside of
  string literals the input passes through unchanged.

  Never raises — any input yields some binary, even if the JSON will
  still fail to parse afterwards.
  """
  @spec repair(binary()) :: binary()
  def repair(json) when is_binary(json) do
    json |> do_repair(false, []) |> IO.iodata_to_binary()
  end

  # do_repair(rest, in_string?, iodata_acc_reversed)
  defp do_repair(<<>>, _in_string, acc), do: Enum.reverse(acc)

  # Outside a string literal — copy verbatim, track " toggling us into a string.
  defp do_repair(<<?", rest::binary>>, false, acc),
    do: do_repair(rest, true, [?" | acc])

  defp do_repair(<<c, rest::binary>>, false, acc),
    do: do_repair(rest, false, [c | acc])

  # Inside a string literal.
  defp do_repair(<<?", rest::binary>>, true, acc),
    do: do_repair(rest, false, [?" | acc])

  # Valid \uXXXX escape — passes through.
  defp do_repair(<<?\\, ?u, h1, h2, h3, h4, rest::binary>>, true, acc)
       when is_hex(h1) and is_hex(h2) and is_hex(h3) and is_hex(h4) do
    do_repair(rest, true, [<<h1, h2, h3, h4>>, "\\u" | acc])
  end

  # Other valid escape (\", \\, \/, \b, \f, \n, \r, \t).
  defp do_repair(<<?\\, next, rest::binary>>, true, acc)
       when is_valid_escape(next) do
    do_repair(rest, true, [<<?\\, next>> | acc])
  end

  # Invalid escape: double the backslash, reconsider `next` on next step.
  defp do_repair(<<?\\, next, rest::binary>>, true, acc) do
    do_repair(<<next, rest::binary>>, true, ["\\\\" | acc])
  end

  # Lone trailing backslash inside an unterminated string — escape it.
  defp do_repair(<<?\\>>, true, acc),
    do: do_repair(<<>>, true, ["\\\\" | acc])

  # Raw control char inside a string — escape it.
  defp do_repair(<<c, rest::binary>>, true, acc) when c in 0x00..0x1F do
    do_repair(rest, true, [escape_control(c) | acc])
  end

  # Everything else (printable bytes, UTF-8 continuations) passes through.
  defp do_repair(<<c, rest::binary>>, true, acc),
    do: do_repair(rest, true, [c | acc])

  @spec escape_control(byte()) :: binary()
  defp escape_control(?\b), do: "\\b"
  defp escape_control(?\f), do: "\\f"
  defp escape_control(?\n), do: "\\n"
  defp escape_control(?\r), do: "\\r"
  defp escape_control(?\t), do: "\\t"

  defp escape_control(c) do
    hex = c |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(4, "0")
    "\\u" <> hex
  end

  @spec close_partial(binary()) :: binary()
  defp close_partial(json) do
    %{in_string: in_string, stack: stack} = scan_brackets(json, false, false, [])

    base =
      if in_string do
        # Inside a string: close it. Don't strip trailing structural
        # chars — they belong to the string literal.
        json <> "\""
      else
        drop_trailing_structural(json)
      end

    base <> :binary.list_to_bin(stack)
  end

  @spec scan_brackets(binary(), boolean(), boolean(), [byte()]) ::
          %{in_string: boolean(), stack: [byte()]}
  defp scan_brackets(<<>>, in_string, _escape_next, stack),
    do: %{in_string: in_string, stack: stack}

  defp scan_brackets(<<_c, rest::binary>>, in_string, true, stack),
    do: scan_brackets(rest, in_string, false, stack)

  defp scan_brackets(<<?\\, rest::binary>>, true, _escape, stack),
    do: scan_brackets(rest, true, true, stack)

  defp scan_brackets(<<?", rest::binary>>, true, _escape, stack),
    do: scan_brackets(rest, false, false, stack)

  defp scan_brackets(<<_c, rest::binary>>, true, _escape, stack),
    do: scan_brackets(rest, true, false, stack)

  defp scan_brackets(<<?", rest::binary>>, false, _escape, stack),
    do: scan_brackets(rest, true, false, stack)

  defp scan_brackets(<<?{, rest::binary>>, false, _escape, stack),
    do: scan_brackets(rest, false, false, [?} | stack])

  defp scan_brackets(<<?[, rest::binary>>, false, _escape, stack),
    do: scan_brackets(rest, false, false, [?] | stack])

  defp scan_brackets(<<?}, rest::binary>>, false, _escape, [?} | stack_rest]),
    do: scan_brackets(rest, false, false, stack_rest)

  defp scan_brackets(<<?], rest::binary>>, false, _escape, [?] | stack_rest]),
    do: scan_brackets(rest, false, false, stack_rest)

  defp scan_brackets(<<_c, rest::binary>>, false, _escape, stack),
    do: scan_brackets(rest, false, false, stack)

  @spec drop_trailing_structural(binary()) :: binary()
  defp drop_trailing_structural(json) do
    trimmed = String.trim_trailing(json)

    case trimmed do
      <<>> ->
        <<>>

      _ ->
        case :binary.last(trimmed) do
          c when c in [?,, ?:] ->
            size = byte_size(trimmed) - 1
            <<head::binary-size(size), _::binary>> = trimmed
            drop_trailing_structural(head)

          _ ->
            trimmed
        end
    end
  end
end
