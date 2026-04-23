defmodule OctoPi.TUI.KeyParser do
  @moduledoc """
  Pure function: raw byte sequence → `{:key, %Key{}}` | `{:char,
  binary}` | `:paste_start | :paste_end | :unknown`.

  Takes a *complete* escape sequence (one the stdin FSM has
  already decided is terminated) plus plain printable input, and
  dispatches via multi-head pattern matching. No top-level
  `case`/`cond` on input shape.

  Supported (Phase 4 MVP):

    * Printable ASCII + Unicode → `{:char, binary}`
    * C0 controls: `\\r` / `\\n` (enter), `\\t` (tab), `\\e`
      (escape), `\\x7f` / `\\b` (backspace), `\\x01..\\x1a` as
      Ctrl+letter
    * Legacy CSI arrows + navigation + F1..F12
    * SS3 arrows (application keypad mode)
    * Kitty CSI-u: `\\e[<cp>;<mod>[:<event>]u`
    * Bracketed paste markers: `\\e[200~` / `\\e[201~`

  Deferred to Phase 4.1:
    * Alt-prefix legacy (`\\e<char>`) for Meta keys
    * Mouse reporting (SGR, X10, X11)
    * Kitty alternate layouts (Cyrillic, Dvorak) via the shifted-
      key + base-layout fields
  """

  alias OctoPi.TUI.Key

  # --- public entry point (multi-head dispatch) ---

  @spec parse(binary()) ::
          {:key, Key.t()} | {:char, binary()} | :paste_start | :paste_end | :unknown

  # Bracketed paste markers come first (concrete byte match).
  def parse("\e[200~"), do: :paste_start
  def parse("\e[201~"), do: :paste_end

  # Named special keys — single-byte C0 controls.
  def parse("\r"), do: {:key, %Key{key: :enter}}
  def parse("\n"), do: {:key, %Key{key: :enter}}
  def parse("\t"), do: {:key, %Key{key: :tab}}
  def parse("\e"), do: {:key, %Key{key: :escape}}
  def parse("\b"), do: {:key, %Key{key: :backspace}}
  def parse("\x7f"), do: {:key, %Key{key: :backspace}}

  # Ctrl+letter: 0x01 (Ctrl+A) through 0x1A (Ctrl+Z).
  # Skip C0 controls that also have named keys above.
  def parse(<<b::8>>) when b in 0x01..0x1A and b not in [0x08, 0x09, 0x0A, 0x0D] do
    {:key, %Key{key: b + 0x60, modifiers: [:ctrl]}}
  end

  # Kitty CSI-u: "\e[<code>;<mod>[:<event>]u"
  def parse(<<"\e[", rest::binary>> = seq) do
    parse_csi(rest, seq)
  end

  # SS3 sequences: "\eO<char>"
  def parse(<<"\eO", final::8>>), do: ss3(final)

  # Printable ASCII.
  def parse(<<b::8>> = c) when b >= 32 and b < 127, do: {:char, c}

  # Printable Unicode (anything that looks like a grapheme).
  def parse(<<_::utf8, _::binary>> = bin), do: {:char, bin}

  def parse(_), do: :unknown

  # --- CSI dispatch ---

  # CSI-u final byte is 'u'; anything else is legacy.
  defp parse_csi(body, _full) do
    case String.last(body) do
      "u" -> parse_kitty_csi_u(body)
      _ -> legacy_csi(body)
    end
  end

  # Legacy CSI table — single-head dispatch via pattern match on
  # the body (the part after "\e[").
  defp legacy_csi("A"), do: {:key, %Key{key: :up}}
  defp legacy_csi("B"), do: {:key, %Key{key: :down}}
  defp legacy_csi("C"), do: {:key, %Key{key: :right}}
  defp legacy_csi("D"), do: {:key, %Key{key: :left}}
  defp legacy_csi("H"), do: {:key, %Key{key: :home}}
  defp legacy_csi("F"), do: {:key, %Key{key: :end}}
  defp legacy_csi("2~"), do: {:key, %Key{key: :insert}}
  defp legacy_csi("3~"), do: {:key, %Key{key: :delete}}
  defp legacy_csi("5~"), do: {:key, %Key{key: :page_up}}
  defp legacy_csi("6~"), do: {:key, %Key{key: :page_down}}
  defp legacy_csi("11~"), do: {:key, %Key{key: :f1}}
  defp legacy_csi("12~"), do: {:key, %Key{key: :f2}}
  defp legacy_csi("13~"), do: {:key, %Key{key: :f3}}
  defp legacy_csi("14~"), do: {:key, %Key{key: :f4}}
  defp legacy_csi("15~"), do: {:key, %Key{key: :f5}}
  defp legacy_csi("17~"), do: {:key, %Key{key: :f6}}
  defp legacy_csi("18~"), do: {:key, %Key{key: :f7}}
  defp legacy_csi("19~"), do: {:key, %Key{key: :f8}}
  defp legacy_csi("20~"), do: {:key, %Key{key: :f9}}
  defp legacy_csi("21~"), do: {:key, %Key{key: :f10}}
  defp legacy_csi("23~"), do: {:key, %Key{key: :f11}}
  defp legacy_csi("24~"), do: {:key, %Key{key: :f12}}
  defp legacy_csi(_), do: :unknown

  # SS3 (application keypad): "\eO<char>"
  defp ss3(?A), do: {:key, %Key{key: :up}}
  defp ss3(?B), do: {:key, %Key{key: :down}}
  defp ss3(?C), do: {:key, %Key{key: :right}}
  defp ss3(?D), do: {:key, %Key{key: :left}}
  defp ss3(_), do: :unknown

  # --- Kitty CSI-u parsing ---

  # `body` here is the part after "\e[", including the trailing "u".
  # Strip the "u" and split on ";" (modifier group), then on ":"
  # (code / shifted / base OR mod / event) — MVP ignores alternate
  # layouts, so we only need the first field of each group.
  defp parse_kitty_csi_u(body) do
    trimmed = binary_part(body, 0, byte_size(body) - 1)

    with {:ok, code, mod_and_event} <- split_code(trimmed),
         {:ok, mod_bits, event} <- split_mod_event(mod_and_event) do
      {:key, %Key{key: code, modifiers: bits_to_modifiers(mod_bits), event_type: event}}
    else
      :error -> :unknown
    end
  end

  # Returns {:ok, codepoint, rest_after_semi_or_empty} | :error
  defp split_code(s) do
    case String.split(s, ";", parts: 2) do
      [head] -> parse_first_int(head, "")
      [head, rest] -> parse_first_int(head, rest)
    end
  end

  defp parse_first_int(head, rest) do
    # The codepoint field may itself be "cp:shifted:base" — MVP only
    # cares about the first segment.
    first = head |> String.split(":") |> hd()

    case Integer.parse(first) do
      {cp, ""} -> {:ok, cp, rest}
      _ -> :error
    end
  end

  # `rest` is the "<mod>[:<event>]" group (or "") after the ';'.
  # An empty rest means no modifier, event_type press.
  defp split_mod_event(""), do: {:ok, 0, :press}

  defp split_mod_event(rest) do
    case String.split(rest, ":", parts: 2) do
      [mod] ->
        with {:ok, n} <- parse_int(mod), do: {:ok, max(n - 1, 0), :press}

      [mod, evt] ->
        with {:ok, mn} <- parse_int(mod),
             {:ok, en} <- parse_int(evt) do
          {:ok, max(mn - 1, 0), event_type(en)}
        end
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp event_type(1), do: :press
  defp event_type(2), do: :repeat
  defp event_type(3), do: :release
  defp event_type(_), do: :press

  # Kitty modifier bitmask: shift=1, alt=2, ctrl=4, super=8.
  # (After subtracting 1 from the reported value.)
  defp bits_to_modifiers(bits) do
    []
    |> put_if(band(bits, 1) != 0, :shift)
    |> put_if(band(bits, 2) != 0, :alt)
    |> put_if(band(bits, 4) != 0, :ctrl)
    |> put_if(band(bits, 8) != 0, :super)
  end

  defp put_if(list, true, mod), do: [mod | list]
  defp put_if(list, false, _), do: list

  defp band(a, b), do: Bitwise.band(a, b)
end
