defmodule OctoPi.TUI.Terminal.KeyParser do
  @moduledoc """
  Pure function: raw byte sequence → `{:key, %Key{}}` | `:paste_start | :paste_end | :unknown`.

  Takes a *complete* escape sequence (one the stdin FSM has
  already decided is terminated) plus plain printable input, and
  dispatches via multi-head pattern matching. No top-level
  `case`/`cond` on input shape.

  Supported:

    * Printable ASCII + Unicode → `{:key, %Key{key: codepoint}}`
    * C0 controls: `\\r` / `\\n` (enter), `\\t` (tab), `\\e`
      (escape), `\\x7f` / `\\b` (backspace), `\\x01..\\x1a` as
      Ctrl+letter, `\\x00` as Ctrl+Space, `\\x1c..\\x1f` as
      Ctrl+symbol
    * Legacy CSI arrows + navigation + F1..F12 + clear
    * SS3 arrows, Home/End, F1..F4 (application keypad mode)
    * Kitty CSI-u: `\\e[<cp>[:<shifted>:<base>];<mod>[:<event>]u`
      with keypad functional key mapping and alternate-layout
      (Cyrillic/Dvorak) base-key resolution
    * xterm modifyOtherKeys: `\\e[27;<mod>;<cp>~`
    * Alt-prefix legacy: `\\e<char>` for Meta keys
    * rxvt modifier variants: `\\e[a..d` (shift+arrow),
      `\\eOa..d` (ctrl+arrow), `$`/`^` suffixes on nav keys
    * Bracketed paste markers: `\\e[200~` / `\\e[201~`
  """

  import Bitwise, only: [band: 2]

  alias OctoPi.TUI.Key

  @paste_start "\e[200~"
  @paste_end "\e[201~"

  # --- public entry point (multi-head dispatch) ---

  @spec parse(binary()) ::
          {:key, Key.t()} | :paste_start | :paste_end | :unknown

  # Bracketed paste markers come first (concrete byte match).
  def parse(@paste_start), do: :paste_start
  def parse(@paste_end), do: :paste_end

  # Named special keys — single-byte C0 controls.
  def parse("\r"), do: {:key, %Key{key: :enter}}
  def parse("\n"), do: {:key, %Key{key: :enter}}
  def parse("\t"), do: {:key, %Key{key: :tab}}
  def parse("\e"), do: {:key, %Key{key: :escape}}
  # Raw 0x08 normally means backspace. Windows Terminal is an
  # outlier: in a local session it maps 0x08 to Ctrl+Backspace. When
  # forwarded over SSH (any of SSH_CONNECTION/SSH_CLIENT/SSH_TTY
  # present) it reverts to plain backspace.
  def parse("\b") do
    if windows_terminal_local?() do
      {:key, %Key{key: :backspace, modifiers: [:ctrl]}}
    else
      {:key, %Key{key: :backspace}}
    end
  end

  def parse("\x7f"), do: {:key, %Key{key: :backspace}}

  # Ctrl+Space (NUL).
  def parse(<<0x00>>), do: {:key, %Key{key: :space, modifiers: [:ctrl]}}

  # Ctrl+letter: 0x01 (Ctrl+A) through 0x1A (Ctrl+Z).
  # Skip C0 controls that also have named keys above.
  def parse(<<b::8>>) when b in 0x01..0x1A and b not in [0x08, 0x09, 0x0A, 0x0D] do
    {:key, %Key{key: b + 0x60, modifiers: [:ctrl]}}
  end

  # Ctrl+symbol: the C0 controls beyond the letter range.
  def parse(<<0x1C>>), do: {:key, %Key{key: ?\\, modifiers: [:ctrl]}}
  def parse(<<0x1D>>), do: {:key, %Key{key: ?], modifiers: [:ctrl]}}
  def parse(<<0x1E>>), do: {:key, %Key{key: ?^, modifiers: [:ctrl]}}
  def parse(<<0x1F>>), do: {:key, %Key{key: ?-, modifiers: [:ctrl]}}

  # CSI sequences: "\e[..."
  def parse(<<"\e[", rest::binary>>), do: parse_csi(rest)

  # SS3 sequences: "\eO<char>"
  def parse(<<"\eO", final::8>>), do: ss3(final)

  # Alt-prefix: ESC followed by a single byte (legacy Meta).
  def parse(<<"\e", b::8>>), do: alt_prefix(b)

  # Printable ASCII.
  def parse(<<b::8>>) when b >= 32 and b < 127, do: {:key, %Key{key: b}}

  # Printable Unicode (non-ASCII codepoint).
  def parse(<<cp::utf8, _::binary>>) when cp >= 128, do: {:key, %Key{key: cp}}

  def parse(_), do: :unknown

  # --- CSI dispatch ---

  defp parse_csi(body) do
    case :binary.last(body) do
      ?u -> parse_kitty_csi_u(body)
      _ -> legacy_csi(body)
    end
  end

  # --- Legacy CSI table ---

  # Arrows.
  defp legacy_csi("A"), do: {:key, %Key{key: :up}}
  defp legacy_csi("B"), do: {:key, %Key{key: :down}}
  defp legacy_csi("C"), do: {:key, %Key{key: :right}}
  defp legacy_csi("D"), do: {:key, %Key{key: :left}}

  # Home / End.
  defp legacy_csi("H"), do: {:key, %Key{key: :home}}
  defp legacy_csi("F"), do: {:key, %Key{key: :end}}

  # Clear (keypad 5).
  defp legacy_csi("E"), do: {:key, %Key{key: :clear}}

  # Insert / Delete / PageUp / PageDown.
  defp legacy_csi("2~"), do: {:key, %Key{key: :insert}}
  defp legacy_csi("3~"), do: {:key, %Key{key: :delete}}
  defp legacy_csi("5~"), do: {:key, %Key{key: :page_up}}
  defp legacy_csi("6~"), do: {:key, %Key{key: :page_down}}

  # Function keys F1..F12.
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

  # Double-bracket (some Linux consoles).
  defp legacy_csi("[5~"), do: {:key, %Key{key: :page_up}}

  # rxvt shift+arrow (lowercase final byte).
  defp legacy_csi("a"), do: {:key, %Key{key: :up, modifiers: [:shift]}}
  defp legacy_csi("b"), do: {:key, %Key{key: :down, modifiers: [:shift]}}
  defp legacy_csi("c"), do: {:key, %Key{key: :right, modifiers: [:shift]}}
  defp legacy_csi("d"), do: {:key, %Key{key: :left, modifiers: [:shift]}}

  # rxvt shift+nav ($ suffix) and ctrl+nav (^ suffix).
  defp legacy_csi("2$"), do: {:key, %Key{key: :insert, modifiers: [:shift]}}
  defp legacy_csi("3$"), do: {:key, %Key{key: :delete, modifiers: [:shift]}}
  defp legacy_csi("5$"), do: {:key, %Key{key: :page_up, modifiers: [:shift]}}
  defp legacy_csi("6$"), do: {:key, %Key{key: :page_down, modifiers: [:shift]}}
  defp legacy_csi("7$"), do: {:key, %Key{key: :home, modifiers: [:shift]}}
  defp legacy_csi("8$"), do: {:key, %Key{key: :end, modifiers: [:shift]}}
  defp legacy_csi("2^"), do: {:key, %Key{key: :insert, modifiers: [:ctrl]}}
  defp legacy_csi("3^"), do: {:key, %Key{key: :delete, modifiers: [:ctrl]}}
  defp legacy_csi("5^"), do: {:key, %Key{key: :page_up, modifiers: [:ctrl]}}
  defp legacy_csi("6^"), do: {:key, %Key{key: :page_down, modifiers: [:ctrl]}}
  defp legacy_csi("7^"), do: {:key, %Key{key: :home, modifiers: [:ctrl]}}
  defp legacy_csi("8^"), do: {:key, %Key{key: :end, modifiers: [:ctrl]}}

  # xterm modifyOtherKeys: "27;<mod>;<cp>~"
  defp legacy_csi(<<"27;", rest::binary>>), do: parse_modify_other_keys(rest)

  # xterm modified arrows/home/end/F1-F4: "1;<mod><final>"
  defp legacy_csi(<<"1;", rest::binary>>), do: xterm_csi_1_param(rest)

  # xterm modified nav/F-keys: "<n>;<mod>~"
  defp legacy_csi(body), do: maybe_xterm_tilde(body)

  # --- SS3 (application keypad): "\eO<char>" ---

  defp ss3(?A), do: {:key, %Key{key: :up}}
  defp ss3(?B), do: {:key, %Key{key: :down}}
  defp ss3(?C), do: {:key, %Key{key: :right}}
  defp ss3(?D), do: {:key, %Key{key: :left}}
  defp ss3(?H), do: {:key, %Key{key: :home}}
  defp ss3(?F), do: {:key, %Key{key: :end}}

  # SS3 function keys.
  defp ss3(?P), do: {:key, %Key{key: :f1}}
  defp ss3(?Q), do: {:key, %Key{key: :f2}}
  defp ss3(?R), do: {:key, %Key{key: :f3}}
  defp ss3(?S), do: {:key, %Key{key: :f4}}

  # rxvt ctrl+arrow via SS3.
  defp ss3(?a), do: {:key, %Key{key: :up, modifiers: [:ctrl]}}
  defp ss3(?b), do: {:key, %Key{key: :down, modifiers: [:ctrl]}}
  defp ss3(?c), do: {:key, %Key{key: :right, modifiers: [:ctrl]}}
  defp ss3(?d), do: {:key, %Key{key: :left, modifiers: [:ctrl]}}

  defp ss3(_), do: :unknown

  # --- Alt-prefix (ESC + single byte) ---

  # Readline-style word navigation.
  defp alt_prefix(?b), do: {:key, %Key{key: :left, modifiers: [:alt]}}
  defp alt_prefix(?f), do: {:key, %Key{key: :right, modifiers: [:alt]}}
  defp alt_prefix(?B), do: {:key, %Key{key: :left, modifiers: [:alt]}}
  defp alt_prefix(?F), do: {:key, %Key{key: :right, modifiers: [:alt]}}

  # rxvt alt+arrow.
  defp alt_prefix(?p), do: {:key, %Key{key: :up, modifiers: [:alt]}}
  defp alt_prefix(?q), do: {:key, %Key{key: :down, modifiers: [:alt]}}

  # Alt+Space / Alt+Backspace / Alt+Enter.
  defp alt_prefix(?\s), do: {:key, %Key{key: :space, modifiers: [:alt]}}
  defp alt_prefix(?\b), do: {:key, %Key{key: :backspace, modifiers: [:alt]}}
  defp alt_prefix(0x7F), do: {:key, %Key{key: :backspace, modifiers: [:alt]}}
  defp alt_prefix(?\r), do: {:key, %Key{key: :enter, modifiers: [:alt]}}
  defp alt_prefix(?\n), do: {:key, %Key{key: :enter, modifiers: [:alt]}}

  # Ctrl+Alt: ESC + C0 control.
  defp alt_prefix(b) when b in 0x01..0x1A and b not in [0x08, 0x09, 0x0A, 0x0D] do
    {:key, %Key{key: b + 0x60, modifiers: [:alt, :ctrl]}}
  end

  # ESC+ESC → Ctrl+Alt+[
  defp alt_prefix(0x1B), do: {:key, %Key{key: ?[, modifiers: [:alt, :ctrl]}}
  defp alt_prefix(0x1C), do: {:key, %Key{key: ?\\, modifiers: [:alt, :ctrl]}}
  defp alt_prefix(0x1D), do: {:key, %Key{key: ?], modifiers: [:alt, :ctrl]}}
  defp alt_prefix(0x1F), do: {:key, %Key{key: ?-, modifiers: [:alt, :ctrl]}}

  # Alt+printable (lowercase letter, digit, or symbol).
  defp alt_prefix(b) when b >= 0x20 and b < 0x7F do
    {:key, %Key{key: b, modifiers: [:alt]}}
  end

  defp alt_prefix(_), do: :unknown

  # --- xterm modified CSI helpers ---

  # "1;<mod><final>" — arrows, Home, End, F1-F4.
  defp xterm_csi_1_param(rest) do
    sz = byte_size(rest)

    if sz >= 2 do
      final = :binary.last(rest)
      mod_str = binary_part(rest, 0, sz - 1)
      key = xterm_1_final_key(final)

      with {:ok, mod} <- parse_int(mod_str), true <- key != :unknown do
        {:key, %Key{key: key, modifiers: bits_to_modifiers(max(mod - 1, 0))}}
      else
        _ -> :unknown
      end
    else
      :unknown
    end
  end

  defp xterm_1_final_key(?A), do: :up
  defp xterm_1_final_key(?B), do: :down
  defp xterm_1_final_key(?C), do: :right
  defp xterm_1_final_key(?D), do: :left
  defp xterm_1_final_key(?H), do: :home
  defp xterm_1_final_key(?F), do: :end
  defp xterm_1_final_key(?P), do: :f1
  defp xterm_1_final_key(?Q), do: :f2
  defp xterm_1_final_key(?R), do: :f3
  defp xterm_1_final_key(?S), do: :f4
  defp xterm_1_final_key(_), do: :unknown

  # "<n>;<mod>~" — nav keys and F5-F12 with modifier.
  defp maybe_xterm_tilde(body) do
    sz = byte_size(body)
    if sz >= 4 and :binary.last(body) == ?~, do: xterm_tilde_split(body, sz), else: :unknown
  end

  defp xterm_tilde_split(body, sz) do
    inner = binary_part(body, 0, sz - 1)

    case String.split(inner, ";", parts: 2) do
      [n_str, mod_str] -> xterm_tilde_parse(n_str, mod_str)
      _ -> :unknown
    end
  end

  defp xterm_tilde_parse(n_str, mod_str) do
    with {:ok, n} <- parse_int(n_str),
         {:ok, mod} <- parse_int(mod_str),
         key when key != :unknown <- xterm_tilde_key(n) do
      {:key, %Key{key: key, modifiers: bits_to_modifiers(max(mod - 1, 0))}}
    else
      _ -> :unknown
    end
  end

  defp xterm_tilde_key(2), do: :insert
  defp xterm_tilde_key(3), do: :delete
  defp xterm_tilde_key(5), do: :page_up
  defp xterm_tilde_key(6), do: :page_down
  defp xterm_tilde_key(11), do: :f1
  defp xterm_tilde_key(12), do: :f2
  defp xterm_tilde_key(13), do: :f3
  defp xterm_tilde_key(14), do: :f4
  defp xterm_tilde_key(15), do: :f5
  defp xterm_tilde_key(17), do: :f6
  defp xterm_tilde_key(18), do: :f7
  defp xterm_tilde_key(19), do: :f8
  defp xterm_tilde_key(20), do: :f9
  defp xterm_tilde_key(21), do: :f10
  defp xterm_tilde_key(23), do: :f11
  defp xterm_tilde_key(24), do: :f12
  defp xterm_tilde_key(_), do: :unknown

  # --- xterm modifyOtherKeys: "27;<mod>;<cp>~" ---
  # `rest` is "<mod>;<cp>~" (the part after "27;").

  defp parse_modify_other_keys(rest) do
    trimmed = String.trim_trailing(rest, "~")

    case String.split(trimmed, ";", parts: 2) do
      [mod_s, cp_s] ->
        with {:ok, mod} <- parse_int(mod_s),
             {:ok, cp} <- parse_int(cp_s) do
          # mok_key/1 lowercases A-Z so binding "shift+a" matches uniformly.
          # Shifted symbols (1→! etc.) are unrecoverable on the wire here:
          # modifyOtherKeys reports the unshifted keysym only, with no
          # alternate-keys field. Insertion of "!" requires kitty flag 4.
          {:key, %Key{key: mok_key(cp), modifiers: bits_to_modifiers(max(mod - 1, 0))}}
        else
          _ -> :unknown
        end

      _ ->
        :unknown
    end
  end

  # Map codepoints to named keys for modifyOtherKeys sequences.
  defp mok_key(13), do: :enter
  defp mok_key(9), do: :tab
  defp mok_key(27), do: :escape
  defp mok_key(127), do: :backspace
  defp mok_key(32), do: :space
  defp mok_key(cp) when cp >= ?A and cp <= ?Z, do: cp + 32
  defp mok_key(cp), do: cp

  # --- Kitty CSI-u parsing ---

  defp parse_kitty_csi_u(body) do
    trimmed = binary_part(body, 0, byte_size(body) - 1)

    with {:ok, raw_cp, shifted_cp, base_cp, mod_and_event} <- split_code(trimmed),
         {:ok, mod_bits, event} <- split_mod_event(mod_and_event) do
      modifiers = bits_to_modifiers(mod_bits)
      build_kitty_key(raw_cp, shifted_cp, base_cp, modifiers, event)
    else
      :error -> :unknown
    end
  end

  defp build_kitty_key(raw_cp, shifted, base, modifiers, event) do
    case keypad_map(raw_cp) do
      {:char_key, c} ->
        {:key, %Key{key: c, modifiers: modifiers, event_type: event}}

      {:named_key, name} ->
        {:key, %Key{key: name, modifiers: modifiers, event_type: event}}

      nil ->
        resolved = resolve_key_with_base(raw_cp, base)
        key = csi_u_named_key(resolved) |> normalize_shifted_letter(modifiers)

        {:key,
         %Key{
           key: key,
           modifiers: modifiers,
           event_type: event,
           shifted_key: shifted_key_for_insertion(shifted)
         }}
    end
  end

  # Per kitty's "alternate keys" reporting (flag 4): when shift is the
  # canonical layout, terminals may still report the keysym in upper-case.
  # Normalize A-Z → a-z so binding "shift+a" matches uniformly across
  # protocols (modifyOtherKeys' mok_key/1 already does the same).
  defp normalize_shifted_letter(cp, modifiers)
       when is_integer(cp) and cp in ?A..?Z do
    if :shift in modifiers, do: cp + 32, else: cp
  end

  defp normalize_shifted_letter(key, _modifiers), do: key

  # Only retain the alternate-keys field when it's a usable printable;
  # callers insert it as text. nil means "terminal didn't tell us".
  defp shifted_key_for_insertion(cp) when is_integer(cp) and cp >= 0x20 and cp != 0x7F, do: cp
  defp shifted_key_for_insertion(_), do: nil

  # Kitty keypad functional keys (codepoints 57399–57426).
  defp keypad_map(n) when n in 57_399..57_408, do: {:char_key, n - 57_399 + ?0}
  defp keypad_map(57_409), do: {:char_key, ?.}
  defp keypad_map(57_410), do: {:char_key, ?/}
  defp keypad_map(57_411), do: {:char_key, ?*}
  defp keypad_map(57_412), do: {:char_key, ?-}
  defp keypad_map(57_413), do: {:char_key, ?+}
  defp keypad_map(57_414), do: {:named_key, :enter}
  defp keypad_map(57_415), do: {:char_key, ?=}
  defp keypad_map(57_416), do: {:char_key, ?,}
  defp keypad_map(57_417), do: {:named_key, :left}
  defp keypad_map(57_418), do: {:named_key, :right}
  defp keypad_map(57_419), do: {:named_key, :up}
  defp keypad_map(57_420), do: {:named_key, :down}
  defp keypad_map(57_421), do: {:named_key, :page_up}
  defp keypad_map(57_422), do: {:named_key, :page_down}
  defp keypad_map(57_423), do: {:named_key, :home}
  defp keypad_map(57_424), do: {:named_key, :end}
  defp keypad_map(57_425), do: {:named_key, :insert}
  defp keypad_map(57_426), do: {:named_key, :delete}
  defp keypad_map(_), do: nil

  # Map well-known codepoints to named key atoms in CSI-u context.
  defp csi_u_named_key(13), do: :enter
  defp csi_u_named_key(9), do: :tab
  defp csi_u_named_key(27), do: :escape
  defp csi_u_named_key(127), do: :backspace
  defp csi_u_named_key(cp), do: cp

  # Alternate-layout resolution: when codepoint is non-Latin
  # and a Latin base is available, use the base. When codepoint
  # IS Latin/printable, prefer it (handles Dvorak correctly).
  defp resolve_key_with_base(cp, nil), do: cp
  defp resolve_key_with_base(cp, _base) when cp in 0x20..0x7E, do: cp
  defp resolve_key_with_base(_cp, base) when base in 0x20..0x7E, do: base
  defp resolve_key_with_base(cp, _base), do: cp

  # Returns {:ok, raw_cp, shifted_cp | nil, base_cp | nil, rest} | :error
  defp split_code(s) do
    case String.split(s, ";", parts: 2) do
      [head] -> parse_code_fields(head, "")
      [head, rest] -> parse_code_fields(head, rest)
    end
  end

  defp parse_code_fields(head, rest) do
    parts = String.split(head, ":")

    case Integer.parse(hd(parts)) do
      {cp, ""} ->
        shifted = parse_optional_int_at(parts, 1)
        base = parse_optional_int_at(parts, 2)
        {:ok, cp, shifted, base, rest}

      _ ->
        :error
    end
  end

  defp parse_optional_int_at(parts, idx) when length(parts) > idx do
    case Enum.at(parts, idx) do
      "" -> nil
      nil -> nil
      s -> parse_int(s) |> elem_or_nil()
    end
  end

  defp parse_optional_int_at(_, _), do: nil

  defp elem_or_nil({:ok, n}), do: n
  defp elem_or_nil(:error), do: nil

  # `rest` is the "<mod>[:<event>]" group (or "") after the ';'.
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
  defp bits_to_modifiers(0), do: []

  defp bits_to_modifiers(bits) do
    []
    |> put_if(band(bits, 1) != 0, :shift)
    |> put_if(band(bits, 2) != 0, :alt)
    |> put_if(band(bits, 4) != 0, :ctrl)
    |> put_if(band(bits, 8) != 0, :super)
  end

  defp put_if(list, true, mod), do: [mod | list]
  defp put_if(list, false, _), do: list

  # Local Windows Terminal: WT_SESSION set and no SSH_* env vars.
  # Over SSH, Windows Terminal re-maps 0x08 so the raw byte becomes
  # a plain backspace again.
  defp windows_terminal_local? do
    System.get_env("WT_SESSION") != nil and
      System.get_env("SSH_CONNECTION") == nil and
      System.get_env("SSH_CLIENT") == nil and
      System.get_env("SSH_TTY") == nil
  end
end
