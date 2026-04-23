# Port map: terminal UI (pi-tui → octo_pi_tui)

Porting spec for Phase 4 — the interactive terminal UI layer with differential
rendering, raw-mode input, keyboard parsing, component architecture, and a
full-featured editor. Built on top of the Phase 3 coding agent
(`OctoPi.Coder`). This is the largest single porting task: upstream is ~11K LOC
TypeScript; Elixir port estimated at ~3.5K LOC due to binary pattern matching
and immutable data structures. Canonical reference: pi-mono v0.69.0 at
`tmp/pi-mono/packages/tui/src/`.

**Primary sources (read first):**
- `tmp/pi-mono/packages/tui/src/terminal.ts` — raw-mode entry, SIGWINCH, Kitty protocol handshake
- `tmp/pi-mono/packages/tui/src/stdin-buffer.ts` — FSM for escape-sequence assembly
- `tmp/pi-mono/packages/tui/src/keys.ts` — CSI-u + legacy key decoding
- `tmp/pi-mono/packages/tui/src/tui.ts` — main render loop, component interface, cursor marker
- `tmp/pi-mono/packages/tui/src/components/editor.ts` — kill ring, undo stack, word-wrap, autocomplete
- `tmp/pi-mono/packages/tui/src/{kill-ring,undo-stack}.ts` — data structures
- `tmp/pi-mono/packages/tui/src/utils.ts` — width calculation, grapheme segmentation
- RESEARCH.md §3.4, §7.Q5, §6.Phase-4, §8.2 — porting notes + raw-mode options

---

## 1. Raw-mode strategy and IO boundary

### 1.1 Problem statement

The equivalent of `process.stdin.setRawMode(true)` (Node) on BEAM is the
OTP 28 first-class raw submode for `-noshell`, introduced in
[PR #8962](https://github.com/erlang/otp/pull/8962). We're on OTP 28.3 for
this project, so this is the primary path.

Key APIs we use:
- `:shell.start_interactive({:noshell, :raw})` — flip the terminal into
  raw mode. No echo, no line editing, keystrokes delivered as they arrive.
- `:shell.start_interactive({:noshell, :cooked})` — restore normal mode
  (the `after` clause in a `try/after`).
- `:io.get_chars("", N)` — read up to N bytes (keystrokes as they
  happen; no Enter required). Reads are **lazy** — the underlying
  syscall only fires when this is called, so nothing accumulates behind
  the app's back.

Also worth knowing:
- `-noinput` is largely obsolete under OTP 28's lazy-read behavior.
- `:io.get_password/0` in stdlib wraps the common "read a secret without
  echo" case.
- A lot of old Windows-in-`-noshell` Unicode weirdness got fixed in the
  same PR (ReadFile now runs in non-overlapped mode).
- The old `io:setopts(standard_io, [{echo, false}, {binary, true}])` dance
  still works for compatibility, but new code should reach for
  `shell:start_interactive({noshell, raw})` directly.

### 1.2 Upstream approach

`ProcessTerminal.start()` (terminal.ts L86-120):
- Calls `process.stdin.setRawMode(true)` at L93.
- Sends CSI 2004 (bracketed paste) at L99.
- Installs `process.stdout` resize listener at L102.
- Sends SIGWINCH to self at L107 to refresh dimensions.
- On Windows, calls `koffi` FFI to set `ENABLE_VIRTUAL_TERMINAL_INPUT` on the
  console (terminal.ts L205-226).

Cleanup (terminal.ts L266-307): restores raw-mode state, disables bracketed
paste, pauses stdin, removes listeners.

### 1.3 Recommended approach: OTP 28 native raw mode

`shell:start_interactive/1` toggles the noshell submode at runtime. Combined
with `io:get_chars/2`, that's everything we need — no NIFs, no shell-outs,
no Ports for the stdin reader.

```elixir
defmodule OctoPi.Tui.RawMode do
  @moduledoc """
  Enter/exit OTP 28 raw noshell mode. Bracket with `try/after` so exit
  runs even if the TUI crashes.
  """

  @spec enter() :: :ok | {:error, term()}
  def enter, do: :shell.start_interactive({:noshell, :raw})

  @spec exit() :: :ok | {:error, term()}
  def exit, do: :shell.start_interactive({:noshell, :cooked})
end
```

Reading a single keystroke:

```elixir
# No Enter required, no echo. Returns a charlist/binary of one codepoint.
{:ok, char} = :io.get_chars("", 1)
```

Stdin reads are **lazy** under OTP 28 — the runtime doesn't greedily buffer
anything; the ReadFile/read() syscall only happens when the process calls
`io:get_chars/2` or equivalent. That's exactly the shape we want: the
Terminal GenServer drives the read loop, nothing runs ahead of it.

There's also `io:get_password/0` in stdlib now, which wraps the common
"read a secret without echo" case — not directly useful for the TUI, but
it's proof the raw-mode plumbing is stable API.

### 1.4 IO boundary sketch

```elixir
defmodule OctoPi.Tui.Terminal do
  use GenServer

  alias OctoPi.Tui.RawMode

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ok = RawMode.enter()

    # Hide cursor, enable bracketed paste, enable focus events.
    IO.write(["\e[?25l", "\e[?2004h", "\e[?1004h"])

    # Route SIGWINCH into this GenServer's mailbox.
    :os.set_signal(:sigwinch, :handle)

    # Spawn a stdin reader that loops on io:get_chars/2 and forwards
    # chunks back here as messages. Because reads are lazy under
    # OTP 28, the reader only blocks when it's actually asking.
    reader = spawn_link(fn -> read_loop(self()) end)

    {:ok, %{reader: reader, cols: term_cols(), rows: term_rows()}}
  end

  @impl true
  def handle_info({:stdin_chunk, bin}, state) do
    OctoPi.Tui.StdinFSM.feed(bin)
    {:noreply, state}
  end

  def handle_info({:signal, :sigwinch}, state) do
    cols = term_cols()
    rows = term_rows()
    OctoPi.Tui.Events.broadcast({:resize, rows, cols})
    {:noreply, %{state | cols: cols, rows: rows}}
  end

  @impl true
  def terminate(_reason, _state) do
    # Restore cursor, disable paste/focus, then cooked mode.
    IO.write(["\e[?25h", "\e[?2004l", "\e[?1004l"])
    RawMode.exit()
  end

  defp read_loop(owner) do
    # Read up to 256 bytes at a time; the FSM handles reassembly.
    case :io.get_chars("", 256) do
      :eof -> :ok
      {:error, _} = err -> send(owner, {:stdin_error, err})
      data -> send(owner, {:stdin_chunk, IO.iodata_to_binary(data)})
    end

    read_loop(owner)
  end

  defp term_cols, do: with({:ok, c} <- :io.columns(), do: c, else: (_ -> 80))
  defp term_rows, do: with({:ok, r} <- :io.rows(),    do: r, else: (_ -> 24))
end
```

**Key design points:**
- `OctoPi.Tui.Terminal` GenServer owns raw-mode lifecycle + SIGWINCH.
- A linked reader process loops on `io:get_chars/2`; because reads are
  lazy, it blocks cheaply when nothing is on stdin.
- `terminate/2` runs on clean shutdown (and on normal supervisor teardown);
  it restores cursor/paste/focus state and exits raw mode.
- Crash recovery: if BEAM exits before `terminate/2` runs (SIGKILL),
  the user's terminal is still in raw mode. Same recovery as every other
  Unix TUI — `stty sane` or `reset`. Document this.
- `:io.columns/0` and `:io.rows/0` give the current window size. OTP 28's
  stdlib returns `{:ok, n} | {:error, :enotsup}`; fall back to 80×24.

### 1.5 MVP startup flow

1. User runs `mix pi` (no `--print`, no `--mode rpc`) → interactive.
2. `Mix.Tasks.Pi.run/1` calls `OctoPi.Tui.start_link/1`.
3. Terminal GenServer enters raw mode, enables paste/focus, installs
   SIGWINCH, spawns the reader.
4. TUI main loop subscribes to session events, renders, handles keys.
5. On Ctrl+C (or ordinary exit), the Terminal GenServer terminates;
   `terminate/2` restores state.

No shell-out in the common path; single GenServer owns the terminal
surface.

---

## 2. SIGWINCH and terminal dimensions

### 2.1 Upstream design

Terminal.ts L102-108: installs a `resize` listener on `process.stdout`. The
Node.js runtime emits this on SIGWINCH. Also manually sends SIGWINCH to self
(L107) to refresh dimensions after suspend/resume (where SIGWINCH was lost).

### 2.2 BEAM constraints

`:os.set_signal/2` (Erlang OTP) allows a process to handle `sigwinch`:

```elixir
:os.set_signal(:sigwinch, :handle)
# Thereafter, the process receives {:signal, :sigwinch}
```

Only the process that calls this receives the signal; others don't (unlike
Unix's global signal delivery). Solution: a dedicated GenServer that owns
SIGWINCH and broadcasts via `Phoenix.PubSub` or a fan-out loop.

### 2.3 OTP design: Terminal GenServer with broadcast

```elixir
defmodule OctoPi.Tui.Terminal do
  use GenServer

  alias OctoPi.Tui.RawMode

  def init(_opts) do
    :ok = RawMode.enter()
    :os.set_signal(:sigwinch, :handle)
    {:ok, %{width: term_cols(), height: term_rows()}}
  end

  def handle_info({:signal, :sigwinch}, state) do
    cols = term_cols()
    rows = term_rows()
    OctoPi.Tui.Events.broadcast({:resize, rows, cols})
    {:noreply, %{state | width: cols, height: rows}}
  end

  defp term_cols, do: with({:ok, c} <- :io.columns(), do: c, else: (_ -> 80))
  defp term_rows, do: with({:ok, r} <- :io.rows(),    do: r, else: (_ -> 24))
end
```

`:io.columns/0` and `:io.rows/0` are stdlib — no shell-out, no NIF, no
ioctl. They return `{:ok, n} | {:error, :enotsup}`; the fallback to 80×24
keeps us safe if the terminal is weird (dumb term, detached).

---

## 3. Stdin FSM: escape-sequence assembly

### 3.1 Problem statement

Stdin data arrives in unpredictable chunks. A CSI sequence like `\x1b[5A`
(page-up) might arrive as `['\x1b', '[5', 'A']` across three events. Without
buffering, the parser sees three separate "keys" instead of one.

### 3.2 Upstream design: StdinBuffer

stdin-buffer.ts implements a simple state machine. Core idea:

1. **Accumulate** incoming data in a `buffer` string.
2. **Detect** complete sequences using regex and state checks:
   - **CSI**: `\x1b[` ... final byte in range `0x40–0x7E` (e.g., `A–Z`, `a–z`).
   - **OSC**: `\x1b]` ... `\x07` (BEL) or `\x1b\\` (ST).
   - **DCS**: `\x1b P` ... `\x1b\\`.
   - **APC**: `\x1b _` ... `\x1b\\`.
   - **SS3**: `\x1b O` + one character.
   - **Meta (Alt)**: `\x1b` + any single character.
   - **Bracketed paste**: `\x1b[200~` ... `\x1b[201~` (special case).
3. **Emit complete sequences** as individual events.
4. **Timeout**: if incomplete after 10ms, flush the buffer as-is (for slow connections).

Classes detected (stdin-buffer.ts L29-78, L132-179):
- **CSI** (Control Sequence Introducer): most arrow keys, function keys, Kitty CSI-u
- **OSC** (Operating System Command): terminal title, Kitty graphics protocol
- **DCS** (Device Control String): XTVersion query responses
- **APC** (Application Program Command): Kitty graphics responses
- **SS3** (Single Shift Three): legacy function keys
- **Meta-key**: `\x1b` + ASCII byte (for Alt key combinations)
- **Bracketed paste**: detected by start marker `\x1b[200~`, buffered until `\x1b[201~`

### 3.3 OTP mapping: Elixir FSM

**Option A: GenServer with accumulated `state: binary`**

```elixir
defmodule OctoPi.Tui.StdinFSM do
  use GenServer

  def init(_opts) do
    {:ok, %{buffer: "", timeout_ref: nil}}
  end

  def handle_call({:process, chunk}, _from, state) do
    cancel_timeout(state.timeout_ref)
    new_buffer = state.buffer <> chunk
    {sequences, remainder} = extract_complete_sequences(new_buffer)
    emit_sequences(sequences)
    new_timeout_ref = schedule_flush(remainder, 10)
    {:reply, :ok, %{buffer: remainder, timeout_ref: new_timeout_ref}}
  end

  def handle_info({:flush_timeout, _ref}, state) do
    if state.buffer != "" do
      emit_sequences([state.buffer])
    end
    {:noreply, %{state | buffer: "", timeout_ref: nil}}
  end

  defp extract_complete_sequences(buffer) do
    # Binary pattern matching to split buffer into complete + remainder
    # See section 3.4 for implementation sketch
    {[], buffer}  # placeholder
  end

  defp emit_sequences(sequences) do
    Enum.each(sequences, &broadcast_sequence/1)
  end

  defp schedule_flush(remainder, ms) when remainder != "" do
    {:ok, ref} = :timer.send_after(ms, {:flush_timeout, ref})
    ref
  end
  defp schedule_flush("", _), do: nil

  defp cancel_timeout(nil), do: :ok
  defp cancel_timeout(ref) do
    :timer.cancel(ref)
  end
end
```

**Option B: Streaming with `Stream.transform/4`**

```elixir
def stdin_stream do
  Stream.unfold({:stdio, ""}, fn
    {device, buffer} ->
      case IO.read(device, 1024) do
        :eof -> nil
        chunk -> extract_and_emit(buffer <> chunk)
      end
  end)
end

defp extract_and_emit(buffer) do
  {sequences, remainder} = extract_complete_sequences(buffer)
  {sequences, {device, remainder}}
end
```

**Recommendation: Option A (GenServer)**. Clearer state management, integrates
cleanly with the Terminal supervisor.

### 3.4 Binary pattern matching for sequence detection

Elixir's binary pattern matching is far simpler than TypeScript's regex loops.

**CSI detection:**
```elixir
defp is_complete_csi(<<"\x1b[", rest::binary>>) do
  case final_byte_index(rest) do
    nil -> false  # incomplete
    idx ->
      last_char = binary_part(rest, idx, 1)
      <<code::8>> = last_char
      # CSI final byte: 0x40 (@) to 0x7E (~)
      code >= 0x40 and code <= 0x7E
  end
end
defp is_complete_csi(_), do: false
```

**OSC detection:**
```elixir
defp is_complete_osc(buffer) do
  case buffer do
    "\x1b]" <> rest ->
      String.contains?(rest, ["\x07", "\x1b\\"])
    _ -> false
  end
end
```

**Meta-key (Alt key):**
```elixir
defp is_complete_meta(<<"\x1b", char::8>>), do: true
defp is_complete_meta(_), do: false
```

**Bracketed paste:**
```elixir
defp extract_paste_content(buffer) do
  case String.split(buffer, "\x1b[200~", parts: 2) do
    [before, after_start] ->
      case String.split(after_start, "\x1b[201~", parts: 2) do
        [content, rest] ->
          {:paste, content, before, rest}
        _ ->
          :incomplete  # waiting for end marker
      end
    _ ->
      :no_paste
  end
end
```

### 3.5 10ms timeout and paste heuristic

**Rationale**: Escape sequences are normally sent atomically by the terminal
driver. If data arrives in pieces, it's usually a slow link (SSH, Mosh) or a
pasted block. Waiting 10ms ensures we batch partial sequences into complete
ones. If 10ms passes with no new data, flush the buffer.

**Paste vs. escape**: The bracketed paste markers (`\x1b[200~` ... `\x1b[201~`)
tell us explicitly when paste mode is active. Outside those markers, raw `\x1b`
starts a key sequence. No ambiguity.

**Implementation**: Use `Process.send_after/3` to schedule a flush timeout. On
each new chunk, cancel and restart the timer. On timeout, emit whatever's left.

---

## 4. Key parser: binary → {key, modifiers}

### 4.1 Upstream design: Kitty CSI-u + legacy fallback

keys.ts parses input into a canonical `KeyId` (e.g., `"ctrl+shift+c"` or `"pageUp"`).
Two protocols:

**Kitty CSI-u** (keys.ts L587-651):
- Modern, unambiguous escape sequences.
- Format: `\x1b[<codepoint>;<modifier>:<event>u`
- Examples:
  - `\x1b[97u` = 'a'
  - `\x1b[97;5u` = Ctrl+a (modifier 5 = Ctrl after subtracting 1)
  - `\x1b[97;5:3u` = Ctrl+a released (event type 3)
  - `\x1b[65:97;5u` = Shift+a, with base layout 'a' (flag 4: alternate keys)

**Legacy sequences** (keys.ts L368-481):
- Arrow keys: `\x1b[A` (up), `\x1b[B` (down), `\x1b[C` (right), `\x1b[D` (left)
- Function keys: `\x1b[11~` (F1), `\x1b[12~` (F2), etc.
- Shift/Ctrl variants: `\x1b[a` (Shift+up), `\x1bOa` (Ctrl+up)
- Meta (Alt): `\x1bb` (Alt+left), `\x1bf` (Alt+right)
- Modifiers: bitmask (shift=1, alt=2, ctrl=4, super=8) stored as `modValue - 1` in CSI

**Kitty protocol feature flags** (keys.ts L145-150):
- Flag 1: disambiguate all keys (even 'a' → `\x1b[97u`)
- Flag 2: report event types (press=1, repeat=2, release=3)
- Flag 4: report alternate keys (for non-Latin layouts)

### 4.2 OTP mapping: pure `parse/1` function

```elixir
defmodule OctoPi.Tui.KeyParser do
  # Main entry point
  def parse(sequence) when is_binary(sequence) do
    cond do
      kitty_csi_u?(sequence) -> parse_kitty_csi_u(sequence)
      legacy_sequence?(sequence) -> parse_legacy(sequence)
      simple_char?(sequence) -> {:char, sequence}
      true -> :unknown
    end
  end

  # CSI-u: \x1b[<code>;<mod>:<event>u
  defp parse_kitty_csi_u(sequence) do
    case sequence do
      <<"\x1b[", code::binary>> ->
        case parse_csi_u_parts(code) do
          {:ok, codepoint, modifier, event_type} ->
            {:key, normalize_key(codepoint, modifier), event_type}
          :error ->
            :unknown
        end
      _ -> :unknown
    end
  end

  defp parse_csi_u_parts(code) do
    # Extract: <codepoint>:<shifted>:<base>;<modifier>:<event>u
    case Integer.parse(code) do
      {cp, rest} ->
        case parse_modifiers_and_event(rest) do
          {:ok, mod, event} -> {:ok, cp, mod, event}
          :error -> :error
        end
      :error -> :error
    end
  end

  # Legacy: \x1b[A, \x1b[11~, \x1bOA, etc.
  defp parse_legacy(sequence) do
    case LEGACY_SEQUENCES[sequence] do
      {:key, key_name} -> {:key, key_name, "press"}
      {:key, key_name, mods} -> {:key, {key_name, mods}, "press"}
      nil -> :unknown
    end
  end

  defp simple_char?(<<char::8>>) when char >= 32 and char < 127, do: true
  defp simple_char?(<<char::utf8, _::binary>>) when char >= 160, do: true
  defp simple_char?(_), do: false

  defp kitty_csi_u?(<<"\\x1b[", _::binary>>), do: true
  defp kitty_csi_u?(_), do: false

  defp legacy_sequence?(seq) do
    Map.has_key?(LEGACY_SEQUENCES, seq)
  end
end

# Legacy sequence table (matching keys.ts L368-481)
@LEGACY_SEQUENCES %{
  "\x1b[A" => {:key, :up},
  "\x1b[B" => {:key, :down},
  "\x1b[C" => {:key, :right},
  "\x1b[D" => {:key, :left},
  "\x1bOA" => {:key, :up},
  "\x1bOB" => {:key, :down},
  "\x1bOC" => {:key, :right},
  "\x1bOD" => {:key, :left},
  "\x1b[11~" => {:key, :f1},
  "\x1b[12~" => {:key, :f2},
  # ... F3–F12, Home, End, Page Up/Down, etc.
  "\x1b[200~" => :paste_start,
  "\x1b[201~" => :paste_end,
}
```

### 4.3 Key struct and event types

**Upstream defines** (keys.ts L141–252): a `KeyId` type union covering:
- Base keys: letters (a–z), digits (0–9), symbols (`, -, =, [, ], etc.), special (escape, enter, tab, space, backspace, delete, insert, home, end, pageUp, pageDown, arrow keys, F1–F12)
- Modifiers: ctrl, shift, alt, super (individually or combined)
- Examples: `"ctrl+shift+c"`, `"pageUp"`, `"alt+x"`, `"super+a"`

**Elixir representation:**

```elixir
defmodule OctoPi.Tui.Key do
  defstruct [
    :key,           # atom: :a, :up, :f1, :enter, :tab, :escape
    modifiers: [],  # list of atoms: [:ctrl, :shift, :alt, :super]
    event_type: :press  # :press, :repeat, :release (Kitty flag 2)
  ]

  def id(%__MODULE__{key: k, modifiers: mods}) do
    mod_str = mods |> Enum.sort() |> Enum.join("+")
    if mod_str == "" do
      Atom.to_string(k)
    else
      "#{mod_str}+#{k}"
    end
  end

  def matches?(%__MODULE__{key: k, modifiers: mods}, target_id) when is_binary(target_id) do
    id(%__MODULE__{key: k, modifiers: mods}) == target_id
  end
end
```

**Key parser output shape:**
```elixir
# Successful parse
{:key, %Key{key: :a, modifiers: [:ctrl], event_type: :press}}

# Simple character
{:char, "a"}

# Unknown
:unknown

# Paste delimiters
:paste_start
:paste_end
```

---

## 5. Differential renderer: line diffing and atomic writes

### 5.1 Upstream design

tui.ts L200–400 implements a **line-by-line diff**. Core flow:

1. **Component renders**: each component's `render(width)` returns `string[]` (array of lines).
2. **Overlay composite**: overlays are composited on top of the base render (see §6).
3. **Line diff**: compare `lines` array against `previousLines`:
   - Find `firstChanged` (first differing line).
   - Find `lastChanged` (last differing line).
   - Reprints only lines in that range.
4. **CSI 2026 wrapping**: if supported, wrap the output in `\x1b[?2026h` (sync
   on) ... `\x1b[?2026l` (sync off) for atomic updates.
5. **Cursor positioning**: move cursor to changed lines, reprint.

**Screen model** (tui.ts): a grid of cells, each with text, foreground, background,
bold, etc. Width-aware: East Asian wide characters and emoji are 2 columns.

**Four full-redraw conditions** (when line-by-line diff is insufficient):
1. Terminal width changed.
2. Terminal height changed.
3. Overlay configuration changed (z-order, visibility).
4. Component tree changed (added/removed components).

### 5.2 OTP mapping: Renderer GenServer

```elixir
defmodule OctoPi.Tui.Renderer do
  use GenServer

  def init(_opts) do
    {:ok, %{
      previous_lines: [],
      previous_width: 80,
      previous_height: 24,
      supports_csi_2026: check_csi_2026_support(),
      subscribers: []
    }}
  end

  def render(components) do
    GenServer.call(__MODULE__, {:render, components}, :infinity)
  end

  def handle_call({:render, components}, _from, state) do
    {width, height} = Terminal.get_dimensions()

    # Check for full-redraw conditions
    full_redraw? =
      width != state.previous_width or
      height != state.previous_height

    # Render all components
    lines = render_components(components, width)

    # Composite overlays (§6)
    lines = composite_overlays(lines, width, height, state.overlays)

    # Diff and write
    output = if full_redraw? do
      full_redraw_output(lines, width, height)
    else
      diff_output(lines, state.previous_lines, width, height)
    end

    # Wrap in CSI 2026 if supported
    output = if state.supports_csi_2026 do
      ["\x1b[?2026h", output, "\x1b[?2026l"]
    else
      output
    end

    Terminal.write(IO.iodata_to_binary(output))

    new_state = %{state |
      previous_lines: lines,
      previous_width: width,
      previous_height: height
    }
    {:reply, :ok, new_state}
  end

  defp render_components(components, width) do
    Enum.flat_map(components, fn comp ->
      lines = comp.render(width)
      Enum.map(lines, &parse_ansi/1)  # Extract colors, bold, etc.
    end)
  end

  defp diff_output(lines, prev_lines, width, height) do
    {first_changed, last_changed} = find_diff_range(lines, prev_lines)

    if first_changed > last_changed do
      # No changes
      []
    else
      # Move cursor and rewrite changed lines
      [
        move_cursor_csi(first_changed, 0),
        Enum.slice(lines, first_changed..last_changed)
          |> Enum.map(&colorize_line/1)
          |> Enum.intersperse("\r\n")
      ]
    end
  end

  defp full_redraw_output(lines, width, height) do
    [
      "\x1b[2J",  # clear screen
      "\x1b[H",   # home (cursor to 1,1)
      lines
        |> Enum.map(&colorize_line/1)
        |> Enum.intersperse("\r\n")
    ]
  end

  defp find_diff_range(lines, prev_lines) do
    # Linear O(n) scan: find first and last differing lines
    first = first_diff_line(lines, prev_lines)
    last = if first > length(lines) - 1 do
      -1
    else
      last_diff_line(lines, prev_lines)
    end
    {first, last}
  end

  defp first_diff_line(lines, prev_lines) do
    Enum.find_index(Enum.zip(lines, prev_lines), fn {l, pl} ->
      l != pl
    end) || length(lines)
  end

  # Check if CSI 2026 (synchronized output) is supported
  defp check_csi_2026_support do
    # Query: send "\x1b[?u" (Kitty protocol), wait for response
    # If we get "\x1b[?<flags>u", protocol is supported
    # For MVP, default to true; can be disabled via env var
    System.get_env("OCTO_PI_NO_CSI_2026") != "1"
  end
end
```

### 5.3 Width-aware line rendering

Upstream uses `get-east-asian-width` (npm) to compute display width of
characters. East Asian wide (CJK, emoji) characters occupy 2 columns; others 1.

**Elixir options:**
1. **Reimplement** via `unicode_data` – simple but big table.
2. **Port to NIF** – calls `wcswidth(3)` or `wcwidth(3)`.
3. **Approximate** – assume all non-ASCII is width 2 (wrong but simple).

**For Phase 4 MVP**: ship with a small lookup table or approximate. Upstream's
`get-east-asian-width` has ~1000 entries. Port the critical ranges.

```elixir
defmodule OctoPi.Tui.Width do
  def visible_width(string) when is_binary(string) do
    string
    |> String.graphemes()
    |> Enum.map(&character_width/1)
    |> Enum.sum()
  end

  # East Asian Wide (CJK, emoji, etc.)
  defp character_width(<<c::utf8>>) when c >= 0x1100 and c <= 0x115F, do: 2
  defp character_width(<<c::utf8>>) when c >= 0x2300 and c <= 0x23FF, do: 2
  # ... (other CJK ranges)
  # Default: 1
  defp character_width(_), do: 1
end
```

### 5.4 CSI 2026 synchronized output

**Problem**: Rapid redraws can flicker (cursor briefly visible mid-update).

**Solution**: CSI 2026 (synchronization mode). Send `\x1b[?2026h` before a batch
of updates, then `\x1b[?2026l` after. Terminal buffers the output and displays
atomically.

**Upstream fallback** (tui.ts L300–350): if CSI 2026 isn't supported, fall back
to non-atomic updates. No errors; the TUI still works, just with potential
flicker.

**OTP implementation**: Wrap all `Terminal.write()` calls in sync markers:

```elixir
def render_with_sync(output) do
  sync_on = if supports_csi_2026?() do
    "\x1b[?2026h"
  else
    ""
  end

  sync_off = if supports_csi_2026?() do
    "\x1b[?2026l"
  else
    ""
  end

  Terminal.write(sync_on <> output <> sync_off)
end
```

---

## 6. Overlay composite and Z-ordering

### 6.1 Upstream design

tui.ts (L100–175) defines `OverlayOptions`: anchor-based positioning, sizing via
percentages or absolutes, margin control, visibility predicates, focus capture.

**Composite logic** (tui.ts, ~L300–350):
1. Render base components → array of lines.
2. For each overlay (in Z order):
   - Compute position and size from anchor + margin + width constraints.
   - Render overlay content.
   - Overlay onto base lines at that position (fill transparency with background).
3. Return composited lines.

**Anchors**: `center`, `top-left`, `top-right`, `bottom-left`, `bottom-right`,
`top-center`, `bottom-center`, `left-center`, `right-center`.

**Sizing**:
- Absolute: `{ width: 50 }` (50 columns).
- Percentage: `{ width: "50%" }` (50% of terminal width).
- Constraints: `minWidth`, `maxHeight`.

### 6.2 OTP mapping

```elixir
defmodule OctoPi.Tui.Overlay do
  defstruct [
    :id,
    :component,
    :anchor,
    :width,
    :max_height,
    :offset_x,
    :offset_y,
    :margin,
    :visible,
    :non_capturing,
    :hidden
  ]

  def compute_rect(%__MODULE__{} = overlay, term_width, term_height) do
    # Parse width and max_height (absolute or percentage)
    width = parse_size(overlay.width, term_width) || term_width
    max_height = parse_size(overlay.max_height, term_height) || term_height

    # Compute position based on anchor
    {anchor_x, anchor_y} = anchor_position(overlay.anchor, term_width, term_height)

    # Apply offset
    x = anchor_x + (overlay.offset_x || 0)
    y = anchor_y + (overlay.offset_y || 0)

    # Clamp to margins
    x = clamp(x, margin_left(overlay.margin), term_width - width - margin_right(overlay.margin))
    y = clamp(y, margin_top(overlay.margin), term_height - max_height - margin_bottom(overlay.margin))

    {:ok, %{x: x, y: y, width: width, height: max_height}}
  end

  defp parse_size(nil, _ref), do: nil
  defp parse_size(n, _ref) when is_integer(n), do: n
  defp parse_size(<<"#{pct}%">>, ref) do
    String.to_integer(pct) * ref / 100 |> round()
  end

  defp anchor_position(:center, w, h), do: {div(w, 2), div(h, 2)}
  defp anchor_position(:top_left, _, _), do: {0, 0}
  defp anchor_position(:top_right, w, _), do: {w, 0}
  # ... etc
end

defmodule OctoPi.Tui.Renderer do
  def composite_overlays(base_lines, overlays, width, height) do
    Enum.reduce(overlays, base_lines, fn overlay, lines ->
      if overlay.hidden or not should_display?(overlay, width, height) do
        lines
      else
        {:ok, rect} = Overlay.compute_rect(overlay, width, height)
        overlay_lines = overlay.component.render(rect.width)
        composite_at(lines, overlay_lines, rect.x, rect.y, rect.width, rect.height)
      end
    end)
  end

  defp composite_at(base_lines, overlay_lines, x, y, width, height) do
    Enum.with_index(base_lines, fn line, row_idx ->
      if row_idx >= y and row_idx < y + height do
        # Overlay this line
        overlay_line = Enum.at(overlay_lines, row_idx - y, "")
        composite_line(line, overlay_line, x, width)
      else
        line
      end
    end)
  end

  defp composite_line(base_line, overlay_line, x, width) do
    # Insert overlay_line at column x, filling width columns
    base_before = String.slice(base_line, 0, x)
    base_after = String.slice(base_line, x + width..-1)
    base_before <> String.pad_trailing(overlay_line, width) <> base_after
  end
end
```

**Key design points:**
- Overlays are composited in render order (last overlay drawn on top).
- Position computation is pure; no side effects.
- Clipping handles overlays that extend beyond terminal edges.
- `non_capturing: true` means overlay doesn't steal focus from components below.

---

## 7. Component behaviour and lifecycle

### 7.1 Upstream interface

tui.ts L16–41 defines the `Component` interface:

```typescript
interface Component {
  render(width: number): string[];
  handleInput?(data: string): void;
  wantsKeyRelease?: boolean;
  invalidate?(): void;
}

interface Focusable {
  focused: boolean;
}
```

**Semantics:**
- `render(width)`: return lines for the given width. Called every frame.
- `handleInput(data)`: receive parsed key or character. Optional.
- `invalidate()`: clear cached state (e.g., on theme change). Optional.
- `focused`: boolean set by TUI; component should render cursor marker when true.

**Mutable state**: upstream components use class fields (`this.state`, `this.value`).

### 7.2 OTP mapping: behaviour + struct-based state

**Behaviour definition:**

```elixir
defmodule OctoPi.Tui.Component do
  @callback render(width :: integer()) :: [String.t()]
  @callback handle_input(component :: term(), data :: String.t()) :: term()
  @callback invalidate(component :: term()) :: term()
  @optional_callbacks [handle_input: 2, invalidate: 1]
end
```

**Concrete component struct:**

```elixir
defmodule OctoPi.Tui.Components.Text do
  @behaviour OctoPi.Tui.Component

  defstruct [
    :content,
    :color,
    :bold
  ]

  def render(%__MODULE__{content: content}, width) do
    # Word-wrap or truncate to width
    content
    |> String.split("\n")
    |> Enum.map(&String.slice(&1, 0, width))
  end

  def invalidate(component), do: component
end

defmodule OctoPi.Tui.Components.Input do
  @behaviour OctoPi.Tui.Component

  defstruct [
    :value,
    :cursor,
    :focused,
    :on_submit
  ]

  def render(%__MODULE__{value: v, cursor: c, focused: f}, width) do
    # Render input field with optional cursor marker
    cursor_marker = if f, do: "\x1b_pi:c\x07", else: ""
    # ... construct line
  end

  def handle_input(%__MODULE__{} = comp, data) do
    case data do
      "\r" -> comp.on_submit.(comp.value); comp
      "\x1b[D" -> %{comp | cursor: max(0, comp.cursor - 1)}  # left
      # ... other keys
      char -> %{comp | value: comp.value <> char, cursor: comp.cursor + 1}
    end
  end
end
```

**Key design points:**
- **No mutable state**: components are immutable structs. Handlers return updated structs.
- **Component lifecycle**: mount/unmount deferred to Phase 4.1 (not critical for MVP).
- **Cursors (IME)**: use the `CURSOR_MARKER` constant (`\x1b_pi:c\x07`). TUI finds and
  positions the hardware cursor there.
- **Property passing**: render functions receive `width` as a parameter. Anything else is
  in the struct (configuration or internal state).

### 7.3 Focusable interface

```elixir
defprotocol OctoPi.Tui.Focusable do
  @doc "Set focus on a component"
  def focus(component)
  @doc "Remove focus from a component"
  def blur(component)
end

defimpl OctoPi.Tui.Focusable, for: OctoPi.Tui.Components.Input do
  def focus(%__MODULE__{} = comp), do: %{comp | focused: true}
  def blur(%__MODULE__{} = comp), do: %{comp | focused: false}
end
```

---

## 8. Editor component (the bulk of the work)

### 8.1 Scope and state

The editor (components/editor.ts, ~2500 lines) supports:
- Multi-line text with cursor positioning.
- Kill ring (Emacs-style yank/yank-pop).
- Undo stack with redo.
- Word-wrap (aware of East Asian wide characters).
- Autocomplete (slash commands, file paths).
- History (up/down arrow navigation).
- Paste tracking (large pastes get ID markers).
- Grapheme-aware cursor movement and deletion.

**Editor state** (components/editor.ts L188–192):
```typescript
interface EditorState {
  lines: string[];
  cursorLine: number;
  cursorCol: number;
}
```

### 8.2 Kill ring (Emacs-style)

Upstream: kill-ring.ts (47 lines). Ring buffer of deleted text. Consecutive
kills accumulate into one entry. `yank()` pastes the most recent; `yank-pop()`
cycles through older entries.

**OTP mapping:**

```elixir
defmodule OctoPi.Tui.KillRing do
  def new, do: {[], 0}  # {entries, current_index}

  def push({entries, _idx}, text, opts) do
    if opts[:accumulate] and Enum.any?(entries) do
      [last | rest] = entries
      new_text = if opts[:prepend] do
        text <> last
      else
        last <> text
      end
      {[new_text | rest], 0}
    else
      {[text | entries], 0}
    end
  end

  def peek({entries, _idx}) do
    case entries do
      [h | _] -> h
      _ -> nil
    end
  end

  def rotate({entries, _idx}) do
    case entries do
      [h | t] -> {t ++ [h], 0}
      _ -> {entries, 0}
    end
  end
end
```

### 8.3 Undo stack

Upstream: undo-stack.ts (29 lines). Stack of deep clones; push clones, pop
returns directly.

```elixir
defmodule OctoPi.Tui.UndoStack do
  def new, do: {[], []}  # {undo, redo}

  def push({undo, _redo}, state) do
    {[state | undo], []}  # Clear redo stack on new edit
  end

  def undo({[prev | undo_rest], redo}) do
    {:ok, prev, {undo_rest, redo}}
  end
  def undo(stack), do: :empty

  def redo({undo, [next | redo_rest]}) do
    {:ok, next, {undo, redo_rest}}
  end
  def redo(stack), do: :empty
end
```

### 8.4 Word-wrap (aware of grapheme clusters)

Upstream: components/editor.ts L101–185. Wraps lines to a max width, respecting
word boundaries. For wide characters (CJK, emoji) and paste markers (which are
atomic), handles them correctly.

**Algorithm:**
1. Segment the line into graphemes via `Intl.Segmenter`.
2. Track visible width (1 column for ASCII, 2 for wide chars, paste marker width varies).
3. On overflow, backtrack to the last space (word break).
4. If no word break, force-break at current position.

**Elixir implementation** (simplified):

```elixir
def word_wrap_line(line, max_width) do
  graphemes = String.graphemes(line)

  Enum.reduce(graphemes, {[], "", 0}, fn g, {chunks, current, width} ->
    g_width = visible_width(g)
    new_width = width + g_width

    if new_width > max_width do
      # Wrap: start a new chunk
      {[current | chunks], g, g_width}
    else
      {chunks, current <> g, new_width}
    end
  end)
  |> elem(1)  # Return accumulated chunks
end
```

### 8.5 Cursor positioning with grapheme awareness

Upstream: components/editor.ts L280+. Cursor moves grapheme-by-grapheme, not
byte-by-byte. For multi-byte UTF-8 or emoji, one keystroke moves past the
entire grapheme.

```elixir
def cursor_left(%Editor{text: text, cursor: cursor}) do
  if cursor > 0 do
    graphemes = String.graphemes(String.slice(text, 0, cursor))
    moved_back = graphemes |> Enum.drop(-1) |> Enum.join() |> String.length()
    %Editor{cursor: moved_back}
  end
end

def cursor_right(%Editor{text: text, cursor: cursor}) do
  if cursor < String.length(text) do
    rest = String.slice(text, cursor..-1)
    [first | _] = String.graphemes(rest)
    %Editor{cursor: cursor + String.length(first)}
  end
end
```

### 8.6 Autocomplete (slash commands, file paths)

Upstream: autocomplete.ts (23K LOC!). Three types:
1. **Slash commands** (e.g., `/read`, `/write`): static list, fuzzy-matched.
2. **File paths**: recursively scanned from cwd, debounced.
3. **Attachments**: uploaded files (deferred to Phase 4.1).

**OTP mapping** (MVP: slash commands only):

```elixir
defmodule OctoPi.Tui.Autocomplete do
  def slash_commands do
    [
      %{name: "read", description: "Read a file"},
      %{name: "write", description: "Write a file"},
      # ...
    ]
  end

  def suggest_slash_commands(prefix) do
    slash_commands()
    |> Enum.filter(fn cmd -> String.starts_with?(cmd.name, prefix) end)
  end

  def file_completions(partial_path, cwd) do
    # Debounce: don't call this every keystroke; batch every 20ms
    # Use Task.async to avoid blocking the UI
    Task.async(fn ->
      full_path = Path.join(cwd, partial_path)
      dir = Path.dirname(full_path)
      prefix = Path.basename(full_path)

      with true <- File.dir?(dir),
           {:ok, files} <- File.ls(dir) do
        files
        |> Enum.filter(fn f -> String.starts_with?(f, prefix) end)
        |> Enum.sort()
      else
        _ -> []
      end
    end)
  end
end
```

**For Phase 4 MVP**: ship with slash commands only. Defer file-path autocomplete
to 4.1 (it's 95% of the upstream code but only 5% of the MVP demand).

---

## 9. Interactive mode integration (TUI + session)

### 9.1 Mode dispatch in octo_pi_coder

Upstream (`pi-coding-agent/src/main.ts` L100+): three modes:
- **Print**: single shot, JSON output.
- **RPC**: JSON-lines stdin/stdout.
- **Interactive**: full TUI.

**OTP mapping**: `OctoPi.Coder.CLI` dispatches on `--mode` flag:

```elixir
defmodule OctoPi.Coder.CLI do
  def main(argv) do
    {args, _rest} = OptionParser.parse!(argv, switches: [mode: :string, ...])

    case args[:mode] || "interactive" do
      "print" -> OctoPi.Coder.PrintMode.run(args)
      "rpc" -> OctoPi.Coder.RpcMode.run(args)
      "interactive" -> OctoPi.Coder.InteractiveMode.run(args)
    end
  end
end
```

### 9.2 InteractiveMode integration

```elixir
defmodule OctoPi.Coder.InteractiveMode do
  def run(args) do
    session_id = args[:session] || UUID.uuid4()
    cwd = args[:cwd] || File.cwd!()

    # Start TUI supervision tree
    {:ok, _pid} = OctoPi.Tui.Supervisor.start_link([])

    # Start agent session
    {:ok, session_pid} = OctoPi.Agent.Session.start_link(
      session_id: session_id,
      model: "claude-opus",
      cwd: cwd
    )

    # Create TUI components
    editor = OctoPi.Tui.Components.Editor.new(
      on_submit: fn text -> handle_user_input(session_pid, text) end
    )

    # Run render loop
    render_loop(session_pid, editor)

    :ok
  end

  defp render_loop(session_pid, editor) do
    # Render editor
    lines = OctoPi.Tui.Renderer.render(editor, 80)  # width from Terminal
    OctoPi.Tui.Terminal.write(render_to_ansi(lines))

    # Poll for new messages
    receive do
      {:input, data} ->
        new_editor = OctoPi.Tui.Component.handle_input(editor, data)
        render_loop(session_pid, new_editor)

      {:agent_update, event} ->
        # LLM streamed a token, update display
        render_loop(session_pid, editor)

      {:signal, :sigwinch} ->
        # Terminal resized
        render_loop(session_pid, editor)

      {:command, :quit} ->
        :ok
    after
      50 ->
        render_loop(session_pid, editor)
    end
  end
end
```

---

## 10. OTP supervision tree

### 10.1 New octo_pi_tui app

```
OctoPi.Tui.Application
├── OctoPi.Tui.Terminal (GenServer)
│   ├── Owns `:stdio` in raw mode
│   ├── Handles SIGWINCH → broadcasts resize
│   └── Provides Terminal.write/1 for output
├── OctoPi.Tui.StdinFSM (GenServer)
│   ├── Accumulates chunks into complete sequences
│   ├── Emits via message to KeyDispatcher
│   └── Manages 10ms timeout flush
├── OctoPi.Tui.KeyDispatcher (GenServer)
│   ├── Receives sequences from StdinFSM
│   ├── Parses via KeyParser
│   └── Routes to focused component
├── OctoPi.Tui.Renderer (GenServer)
│   ├── Holds previous render state
│   ├── Computes diffs, outputs CSI 2026 wrapped
│   └── Manages overlay Z-order
└── OctoPi.Tui.ComponentTree (dynamic)
    ├── Various components (Editor, Text, SelectList, ...)
    └── Per-component state (if stateful)
```

**Integration with octo_pi_coder:**

```
OctoPi.Coder.InteractiveMode
├── Starts OctoPi.Tui.Supervisor
├── Subscribes to OctoPi.Agent.Session events
├── Renders session state via TUI components
├── Routes TUI input (editor submit, escape, etc.) back to session
└── Listens for SIGWINCH → triggers full redraw
```

---

## 11. Hard parts and gotchas

### 11.1 Raw-mode ownership and TTY setup

**Problem**: `shell:start_interactive({noshell, raw})` flips the entire
BEAM VM's stdio into raw mode. If someone has an IEx session attached or a
mix task expects cooked input, they'll see strange behavior until we
restore.

**Solution for development**:
- Use `MIX_ENV=test` to avoid TUI entirely during tests.
- Add a `--no-tui` flag to the CLI for debugging.
- The Terminal GenServer's `terminate/2` runs `RawMode.exit()` on normal
  shutdown; that covers the supervised case.

**Crash recovery**: If the BEAM VM dies abruptly (SIGKILL, OOM, `erl -s
halt`), `terminate/2` doesn't run and the terminal stays in raw mode.
Standard Unix recovery: user types `reset` or `stty sane` blindly (their
typing won't echo until it lands). Document this; every TUI has the same
failure mode.

### 11.2 SIGWINCH delivery and multiple processes

**Problem**: Only the process that called `:os.set_signal(:sigwinch, :handle)`
receives SIGWINCH. If the renderer process dies, resizes go undelivered.

**Solution**: Have the Terminal GenServer own SIGWINCH and broadcast via PubSub.
The renderer subscribes. On resize, all subscribers are notified.

### 11.3 Wide-character rendering inconsistency

**Problem**: Terminals disagree on display width of edge cases:
- Emoji in Kitty vs. Alacritty vs. xterm: 1 or 2 columns?
- Regional indicators (flag emoji): sometimes 1, sometimes 2 per component?
- Combining diacritics: 0 width or 1?

**Solution**: Ship with a conservative width table (East Asian Width standard).
If rendering looks wrong (column misalignment), ask users to report terminal +
character. Add a `--debug-widths` flag to log character widths.

### 11.4 Paste-vs-escape disambiguation

**Problem**: Paste arrives as raw bytes, no distinguishing header (unless
bracketed paste is enabled). Escape sequence for a slow connection might
look like a partial paste.

**Solution**: Upstream relies on bracketed paste markers (`\x1b[200~` ... `\x1b[201~`).
Send these in Terminal.start() (terminal.ts L99). If a terminal doesn't support
them, pastes will be split into individual characters (bad UX, not broken logic).

### 11.5 Redo and paste markers

**Problem**: Paste markers like `[paste #1 +123 lines]` are embedded in the text.
If the user undoes past a paste, then redoes, the marker ID is stale.

**Solution** (upstream): maintain a `validPasteIds` set. Only treat markers
with valid IDs as atomic. Invalid markers are treated as regular text.

### 11.6 Terminal restoration on crash

**Problem**: Unhandled exception in the TUI renders the terminal unusable.

**Solution**: wrap the entire render loop in a `try` block that always calls
`Terminal.disable_raw_mode()` in the finally clause. Use a custom `catch_all`
handler at the top level.

```elixir
try do
  render_loop(session_pid, editor)
rescue
  e ->
    IO.inspect(e, label: "TUI error")
    OctoPi.Tui.Terminal.restore()
    reraise e, __STACKTRACE__
end
```

### 11.7 Flicker avoidance: CSI 2026 fallback

**Problem**: Not all terminals support CSI 2026 (synchronized output).

**Solution**: Check for support at startup (send a query, see if we get a
response). If not supported, still render correctly, just with potential flicker.
No errors; graceful degradation.

---

## 12. Critical path and defer list

### 12.1 Must-ship (Phase 4 DoD)

- [ ] Raw-mode strategy implemented and tested on Linux/macOS.
- [ ] SIGWINCH handling and resize events broadcast.
- [ ] StdinFSM: complete escape-sequence assembly from partial chunks.
- [ ] KeyParser: legacy CSI + CSI-u decoding.
- [ ] Renderer: line-by-line diff, CSI 2026 if available.
- [ ] Editor: basic insert/delete, cursor left/right, home/end, Ctrl+A/E.
- [ ] Submit (Enter), escape (Ctrl+C), minimal keybindings.
- [ ] Interactive mode glue: `mix pi` opens TUI, renders assistant turns.
- [ ] Component lifecycle: render/handle_input/invalidate.

**Success criterion**: `mix pi` opens an interactive TUI that:
- Accepts text input without hangs.
- Streams assistant output in real-time.
- Lets you type a follow-up and continue the conversation.
- Exits cleanly on Ctrl+C.
- Restores the terminal.

### 12.2 Defer to Phase 4.1

- [ ] Kitty protocol progressive enhancement (flag 2/4 for key events).
- [ ] Kill ring (`Ctrl+Y` / `Meta+Y`).
- [ ] Undo stack (`Ctrl+_`).
- [ ] Slash-command autocomplete.
- [ ] File-path autocomplete and tab completion.
- [ ] Bracketed paste support (works, but not optimized).
- [ ] History (up/down arrow navigation).
- [ ] SelectList component.
- [ ] Markdown rendering component.
- [ ] Mouse support.
- [ ] Images (Kitty graphics protocol).
- [ ] Windows support (different TTY handling).

---

## 13. Tests to port

### 13.1 StdinFSM

**Upstream**: `test/input.test.ts` (partial sequences, CSI, OSC, bracketed paste,
timeout flush).

**Elixir tests:**

```elixir
defmodule OctoPi.Tui.StdinFSMTest do
  use ExUnit.Case

  test "assembles CSI sequence from three chunks" do
    fsm = OctoPi.Tui.StdinFSM.new()
    {:ok, fsm, []} = OctoPi.Tui.StdinFSM.process(fsm, "\x1b")
    {:ok, fsm, []} = OctoPi.Tui.StdinFSM.process(fsm, "[5")
    {:ok, _fsm, [seq]} = OctoPi.Tui.StdinFSM.process(fsm, "A")
    assert seq == "\x1b[5A"
  end

  test "flushes after 10ms timeout" do
    fsm = OctoPi.Tui.StdinFSM.new()
    {:ok, fsm, []} = OctoPi.Tui.StdinFSM.process(fsm, "\x1b[")
    Process.sleep(15)
    {:ok, _fsm, sequences} = OctoPi.Tui.StdinFSM.flush(fsm)
    assert sequences == ["\x1b["]
  end

  test "detects bracketed paste boundaries" do
    fsm = OctoPi.Tui.StdinFSM.new()
    {:ok, fsm, []} = OctoPi.Tui.StdinFSM.process(fsm, "\x1b[200~hello\x1b[201~")
    {:ok, _fsm, events} = OctoPi.Tui.StdinFSM.flush(fsm)
    assert events == [{:paste, "hello"}]
  end
end
```

### 13.2 KeyParser

**Upstream**: `test/keys.test.ts` (100+ cases: CSI-u, legacy, modifiers, edge cases).

```elixir
defmodule OctoPi.Tui.KeyParserTest do
  use ExUnit.Case

  test "parses Kitty CSI-u" do
    assert OctoPi.Tui.KeyParser.parse("\x1b[97u") ==
      {:key, %OctoPi.Tui.Key{key: :a, modifiers: []}}
  end

  test "parses CSI-u with Ctrl modifier" do
    assert OctoPi.Tui.KeyParser.parse("\x1b[97;5u") ==
      {:key, %OctoPi.Tui.Key{key: :a, modifiers: [:ctrl]}}
  end

  test "parses legacy arrow key" do
    assert OctoPi.Tui.KeyParser.parse("\x1b[A") ==
      {:key, %OctoPi.Tui.Key{key: :up, modifiers: []}}
  end

  test "parses simple character" do
    assert OctoPi.Tui.KeyParser.parse("a") == {:char, "a"}
  end
end
```

### 13.3 Renderer diff

**Upstream**: `test/tui-render.test.ts` (snapshot tests of diffs).

```elixir
defmodule OctoPi.Tui.RendererTest do
  use ExUnit.Case

  test "diff detects single line change" do
    old_lines = ["line 1", "line 2", "line 3"]
    new_lines = ["line 1", "CHANGED", "line 3"]
    {first, last} = OctoPi.Tui.Renderer.find_diff_range(new_lines, old_lines)
    assert first == 1
    assert last == 1
  end

  test "full redraw on width change" do
    # Render with width 80, then 120
    # Should output a full clear+redraw, not a diff
    :ok
  end
end
```

### 13.4 Editor

**Upstream**: `test/editor.test.ts` (insertion, deletion, movement, word-wrap, undo).

```elixir
defmodule OctoPi.Tui.Components.EditorTest do
  use ExUnit.Case

  test "inserts character at cursor" do
    editor = OctoPi.Tui.Components.Editor.new()
    editor = OctoPi.Tui.Components.Editor.handle_input(editor, "a")
    assert editor.text == "a"
  end

  test "cursor moves left with arrow" do
    editor = OctoPi.Tui.Components.Editor.new(text: "abc")
    editor = %{editor | cursor: 3}  # after 'c'
    editor = OctoPi.Tui.Components.Editor.handle_input(editor, "\x1b[D")  # left
    assert editor.cursor == 2
  end

  test "word-wraps at boundary" do
    lines = OctoPi.Tui.Components.Editor.word_wrap_line("hello world", 7)
    assert lines == ["hello", "world"]
  end
end
```

---

## 14. Upstream tests to mirror

The upstream `tmp/pi-mono/packages/tui/test/` directory is the richest source of
port fidelity we have — several subsystems (stdin FSM, key parser, markdown
renderer) have test files 500-1200+ lines covering edge cases won the hard
way. For each Phase 4 subticket, lift the case list below into the "Tests to
land" bullet list; the ExUnit harness patterns in §13 show how to structure
them.

### 14.1 Input handling & autocomplete

- **`autocomplete.test.ts`** (542 lines) — path completion against cwd with
  fuzzy matching. Cases: absolute vs relative path prefixes, `./` handling,
  case-insensitive filtering, dirs-before-files ranking, nested paths,
  symlinks, hidden files (exclude `.git`, include `.pi` and `.github`), quote
  continuation inside `@refs`, quote deduplication when applying.
  **ExUnit port**: needs tmp dir + symlinks (`File.mkdir_p!`, `File.ln_s!`,
  platform-skip on Windows). Stub `fd` via shell-out mock. Quote logic is
  pure string; ports as-is.

- **`input.test.ts`** (580 lines) — single-line input component: editing,
  kill ring, undo. Cases: wide CJK insertion, cursor tracking under
  horizontal scroll, Ctrl+W/U/K/Alt+D save-delete-yank cycles, Alt+Y yank-pop
  cycling (fwd and back), undo coalescing (consecutive chars = 1 unit, spaces
  split), undo across cursor movement, bracketed paste undoes atomically.
  **ExUnit port**: pure state machine — ports cleanly. Test harness mocks
  escape code input.

- **`stdin-buffer.test.ts`** (422 lines) — escape sequence buffering and
  reassembly (the FSM heart). Cases: ASCII/Unicode passthrough, complete vs
  partial sequences split across chunks, timeout-flush after 10ms, SGR mouse,
  old-style X11 mouse (`ESC M + 3 bytes`), arrows, function keys, SS3, meta,
  Kitty press/release/repeat events, Kitty functional keys with modifiers,
  bracketed paste split across chunks, paste with Unicode, flush/destroy.
  **ExUnit port**: pure binary processing — ports cleanly. Timeout uses
  `Process.send_after/3` in production, mock timer in tests.

### 14.2 Keybindings & key parsing

- **`keybindings.test.ts`** (38 lines) — binding manager conflict detection.
  Cases: default bindings not evicted by user rebinds to same key, navigation
  preserved alongside user bindings, direct-conflict reporting without
  eviction.
  **ExUnit port**: pure configuration — trivial port.

- **`keys.test.ts`** (615 lines) — the big one. Kitty CSI-u, xterm
  modifyOtherKeys, legacy sequences. Cases: Kitty CSI-u alternate keys
  (Cyrillic, Dvorak, swapped layouts), keypad functional keys, press/repeat/
  release event types, shifted keys + full format with base layout, xterm
  Ctrl/Shift/Alt + letter/symbol/digit/arrow/special, legacy Ctrl+letter
  (ASCII 0-31), escape/space/backspace variants, Windows Terminal local vs
  SSH distinction for Ctrl+Backspace, `ESC+X` legacy Alt prefix, arrow CSI
  vs SS3, F1-F12 + clear, env-aware parsing (`SSH_CONNECTION`, `WT_SESSION`),
  `decodeKittyPrintable/decodePrintableKey`, parse-key name normalization,
  preference: codepoint > base layout > no alternate.
  **ExUnit port**: pure parsing — ports directly. Env vars via `System.get_env/1`
  in tests.

### 14.3 Text rendering & formatting

- **`truncate-to-width.test.ts`** (56 lines) — ANSI-aware truncation with
  ellipsis. Cases: 100k+ char inputs safely clipped, reset before ellipsis,
  malformed ANSI doesn't hang, wide ellipsis (emoji) with proper brackets,
  ellipsis wider than space (clip or ""), exact-width padding, trailing
  reset without ellipsis, `visibleWidth` (tabs configurable, ANSI skipped).
  **ExUnit port**: pure — ports directly. East Asian Width for CJK/emoji is
  the only external concern (library or static table).

- **`truncated-text.test.ts`** (130 lines) — component-level truncate + pad.
  Cases: exact-width no-padding, vertical padding (top+content+bottom), long
  text with ellipsis, styled text preserved + reset, empty text, multiline
  (stops at first newline), first-line truncation with embedded newlines.
  **ExUnit port**: wraps truncate-to-width — ports as-is.

- **`wrap-ansi.test.ts`** (207 lines) — ANSI-aware word/grapheme wrap. Cases:
  underline isolation (not applied before styled segment), underline-bleed
  prevention (reset only underline, not full reset for padding), background
  color preserved across wraps, nested underline inside bg, plain text wrap
  + width verification, color code preservation on continuation, ANSI
  restoration at line start, trailing whitespace truncation, OSC 133
  semantic markers ignored in width calc, OSC 8 hyperlinks re-emit open at
  continuation + close before break, regional indicator emoji at width 2
  during streaming.
  **ExUnit port**: core wrap state machine for ANSI tracking — ports well.
  OSC handling is pattern-based.

- **`markdown.test.ts`** (1200+ lines) — markdown rendering (tables, lists,
  blockquotes, inline formatting, links, headings). Cases: nested lists
  (un/ordered/mixed), ordered-list numbering preserved when code blocks
  unindented (LLM output), tables with full border set, column width, cell
  wrapping at narrow widths without breaking borders, long unbroken tokens
  (URLs) inside cells, styled inline code in cells, extremely narrow width
  (graceful), blockquotes (lazy continuation, multiline, list nesting),
  style isolation (blockquote not leaked from pre-styled text), heading
  styling after inline code + bold, H1 underline not leaked to padding,
  strikethrough, links (parenthesized URL, OSC 8 hyperlinks, mailto, bare
  URL autolinks), HTML-like tags in text, code block spacing (1 blank
  after, none trailing last), divider spacing, blockquote styling after
  inline elements, pre-styled text (thinking traces: gray + italic preserved
  after inline code/bold), TUI integration (no style leak to following
  lines).
  **ExUnit port**: heaviest upstream test. Needs a markdown parser (marked
  equivalent — `Earmark` is the Elixir standard). Assertion patterns (ANSI
  regex strip, width checks) port. Wide-character width handling is
  critical for CJK test cases.

### 14.4 List & selection components

- **`select-list.test.ts`** (116 lines) — multi-column list layout. Cases:
  multiline descriptions → single line (newlines → spaces), alignment
  across items, min/max primary column width, custom primary truncation,
  ellipsis preserving description alignment, description at same column
  regardless of primary length.
  **ExUnit port**: pure layout — ports directly.

- **`fuzzy.test.ts`** (98 lines) — fuzzy matching + filtering. Cases: empty
  query = match all with score 0, query longer than text = no match, exact
  match = best score, char order required (abc ≠ cba), case-insensitive,
  consecutive > scattered, word boundary bonus (`foo-bar` matches `fb`
  better than `afbx`), swapped alphanumeric tokens (`codex52` matches
  `gpt-5.2-codex`), sorting by match quality, custom `getText` for objects.
  **ExUnit port**: pure scoring — ports directly.

### 14.5 TUI core & rendering

- **`tui-render.test.ts`** (510 lines) — differential rendering, resize,
  shrinkage, viewport. Cases: full re-render on height/width change, Termux
  height-change suppression (no clear, no full redraw), content shrinkage
  clears empty rows, shrink-to-single-line + shrink-to-empty, cursor
  tracking when content shrinks, middle-line change detection (spinner),
  styles reset after each line (no italic bleed), first-line-only diff,
  last-line-only diff, multiple non-adjacent line changes, empty-to-content
  transitions, viewport move on large shrink (full redraw), append after
  shrink stays on diff path, stale content cleared when transient
  component inflates + shrinks, full redraw on component branch switch.
  **ExUnit port**: core differential engine. Needs a mock terminal with
  cell-level inspection. Termux detection via `TERMUX_VERSION` env. Full
  redraw vs diff decision tree is critical — port the algorithm exactly.

- **`overlay-options.test.ts`** (538 lines) — overlay positioning, sizing,
  compositing. Cases: width overflow protection, complex ANSI (nested
  colors, OSC 8) without crash, styled base + overlay composite, wide chars
  at boundary, overlay at terminal edge, OSC 8 in base content (original
  crash repro), width percentage (50% of term), minWidth constraint,
  anchor positioning (top-left/br/center/etc), margin as number + object,
  negative margins clamped to 0, offset from anchor, row/col as %, absolute
  row/col override, maxHeight absolute + percent, stacked overlays
  (later-on-top), overlay hide (pop, reveal previous).
  **ExUnit port**: layout + compositing math — pure. Needs mock terminal
  and component interface. OSC handling is pattern-based.

- **`tui-cell-size-input.test.ts`** (82 lines) — cell dimension query
  response filtering. Cases: bare ESC forwarded to input, cell-size responses
  consumed (not forwarded), later user input forwarded after consuming
  response, image terminal setup/teardown env cleanup.
  **ExUnit port**: IO filtering — straightforward with env var mgmt via
  `System.put_env/1` + try/after cleanup.

### 14.6 Regression repros (port verbatim)

These are bug-fix tests from hard-won incidents. Port the scenarios literally;
they're cheap insurance.

- **`bug-regression-isimageline-startswith-bug.test.ts`** (237 lines) — image
  line detection on huge lines. Cases: 300KB lines don't hang, iTerm2 sequence
  (`\x1b]1337;File=...`) at start/mid/end, Kitty sequence (`\x1b_Ga=...`)
  anywhere, ANSI codes before image sequence, false-positive avoidance in
  plain text + file paths.
  **ExUnit port**: pure pattern detection — trivial. `String.contains?/2` is
  the Elixir equivalent of `includes`.

- **`regression-regional-indicator-width.test.ts`** (52 lines) — emoji
  streaming width stability. Cases: partial flag graphemes (U+1F1E6-
  U+1F1FF solo) measured as width 2 not 1 — prevents diff drift when
  partial flag appears mid-stream; full flag pairs stay width 2; common
  intermediates stable (👍, ✅, 👨‍💻, 🏳️‍🌈); wrapping respects width 2.
  **ExUnit port**: East Asian Width dependency is the only real work — pure
  math once width known.

### 14.7 Coverage gaps — write fresh in Phase 4

Upstream test coverage is sparse for:

1. **Differential renderer algorithm internals** — `tui-render.test.ts`
   covers *behavior* but not the line-diff algorithm itself. We need fresh
   ExUnit for: unchanged vs changed line detection, cursor-position calc on
   shrink, viewport reset conditions, ANSI state machine across lines.

2. **Editor component deep internals** — there's an upstream `editor.test.ts`
   but it's ~59K tokens (DOM + scroll-position heavy). Audit it first; expect
   to lift 30-50% of scenarios (pure edit state logic) and write fresh for
   scroll/viewport details.

3. **Mouse gesture semantics** — upstream tests only decode mouse events in
   `stdin-buffer.test.ts`. Click-detection, region-checking, drag gestures
   need fresh tests.

4. **Terminal image rendering** — only the regression repro exists. Format-
   specific rendering (iTerm2, Kitty, Sixel) needs fresh coverage.

5. **Theme / color palette** — fixtures exist (`test-themes.ts`) but no
   dedicated theme test. Markdown tests stub theme. Phase 4 may need color
   space / palette tests if we support user themes.

### 14.8 Non-test files (ignore)

Several files in upstream's `test/` directory are not actually test suites
— fixtures, manual harnesses, or experiments:

- `chat-simple.ts`, `image-test.ts`, `key-tester.ts`,
  `viewport-overwrite-repro.ts` — manual test harnesses
- `test-themes.ts`, `virtual-terminal.ts` — fixtures / helpers

Don't port these; the helpers we'll replace with ExUnit idioms.

---

## 15. Estimates and timeline

| Task                                   | LoC | Effort (days) |
|----------------------------------------|-----|---------------|
| Terminal (raw mode, SIGWINCH, Port)   | 200 | 1             |
| StdinFSM (FSM + binary patterns)      | 250 | 1             |
| KeyParser (CSI-u + legacy)            | 300 | 2             |
| Renderer (diff, CSI 2026, overlay)    | 400 | 3             |
| Editor core (insert, delete, wrap)    | 600 | 4             |
| Components (Input, Text, SelectList)  | 300 | 2             |
| Interactive mode + glue               | 250 | 2             |
| Tests                                 | 400 | 3             |
| **Total**                             | 2,700 | **18 days** |

**Parallelizable:** Terminal, StdinFSM, KeyParser can be built and tested independently.
Renderer depends on KeyParser but not Terminal. Editor depends on everything.

---

## 16. Windows and cross-platform notes

### 16.1 Windows TTY

Windows console doesn't support POSIX termios, but OTP 28's `-noshell raw`
submode handles Windows too — the same PR that introduced raw mode also
[fixed](https://github.com/erlang/otp/pull/8962) a pile of Windows Unicode
weirdness (aborted overlapped reads, `ReadFile` running in non-overlapped
mode, etc.). Upstream pi-mono had to `koffi`-FFI `ENABLE_VIRTUAL_TERMINAL_INPUT`
onto the console handle (terminal.ts L205-226); we get that for free.

That said, **Phase 4 MVP targets Unix (Linux, macOS, BSD)** — we still
haven't exercised the OTP 28 Windows path ourselves and it's not a Phase 4
goal. If the tests pass on Windows, great; if not, Phase 4.1 can chase it.

### 16.2 macOS Homebrew integration

Upstream's `pi` CLI ships as an npm package. Homebrew has limited Node.js
integration, so users must install Node first.

`octo_pi` (Elixir + Burrito) ships as a single static binary. **No dependency on
Node or Erlang being installed on the user's system.** This is a huge UX win.

### 16.3 SSH/Tmux considerations

**SSH**: Slow links (high latency) make 10ms timeouts dangerous (partial sequences
time out and are emitted early). **Mitigation**: upstream sends `\x1bP>|[VERSION]\x1b\\`
(DCS version query) early on, waits for response, uses response time as a heuristic
for link speed. Deferred to Phase 4.1.

**Tmux**: Needs `-t` flag to enable extended keys. **For MVP**: document that
users must run `set -g extended-keys on` in their `~/.tmux.conf`. Or auto-detect
tmux and send the command.

---

## Appendix: Key constants from upstream

### Codepoint constants (keys.ts L301–324)

```elixir
@CODEPOINTS %{
  escape: 27,
  tab: 9,
  enter: 13,
  space: 32,
  backspace: 127
}

@ARROW_CODEPOINTS %{
  up: -1,
  down: -2,
  right: -3,
  left: -4
}

@FUNCTIONAL_CODEPOINTS %{
  delete: -10,
  insert: -11,
  pageUp: -12,
  pageDown: -13,
  home: -14,
  end: -15
}

@MODIFIERS %{
  shift: 1,
  alt: 2,
  ctrl: 4,
  super: 8
}
```

### Legacy sequence table (subset of keys.ts L368–481)

```elixir
@LEGACY_SEQUENCES %{
  "\x1b[A" => :up,
  "\x1b[B" => :down,
  "\x1b[C" => :right,
  "\x1b[D" => :left,
  "\x1b[H" => :home,
  "\x1b[F" => :end,
  "\x1b[11~" => :f1,
  "\x1b[12~" => :f2,
  # ... F3–F12
  "\x1b[2~" => :insert,
  "\x1b[3~" => :delete,
  "\x1b[5~" => :pageUp,
  "\x1b[6~" => :pageDown
}
```

---

End of port map.
