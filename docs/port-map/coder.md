# Port map: coding agent (pi-coding-agent → octo_pi_coder)

Porting spec for Phase 3 — the stateful coding-agent application layer, file
tools, bash execution, session persistence, and Print + RPC modes. Built on top
of the Phase 2 kernel (`OctoPi.Agent`). Phase 4 (Interactive TUI) is deferred.
Canonical reference: pi-mono v0.69.0 at
`tmp/pi-mono/packages/coding-agent/src/`.

**Primary sources (read first):**
- `tmp/pi-mono/packages/coding-agent/src/migrations.ts` — session/config migrations
- `tmp/pi-mono/packages/coding-agent/src/core/agent-session.ts` — session state, JSONL format
- `tmp/pi-mono/packages/coding-agent/src/core/tools/{read,write,edit,bash}.ts` — tool schemas and handlers
- `tmp/pi-mono/packages/coding-agent/src/core/file-mutation-queue.ts` — per-file mutex design
- `tmp/pi-mono/packages/coding-agent/src/modes/{print-mode,rpc/rpc-mode}.ts` — output modes
- `tmp/pi-mono/packages/coding-agent/src/cli/args.ts`, `src/main.ts` — CLI entry

---

## 1. Session file format (JSONL v3)

### 1.1 Layout and schema

Sessions are JSONL files at `~/.pi/agent/sessions/--<encoded-cwd>--/<uuid>.jsonl`.
Each line is a JSON object with a `type` field. First line is always a
`SessionHeader`; remaining lines are typed entries. **Format must be
byte-compatible with upstream `pi` v0.69.0** to allow session sharing and
cross-version reads.

**SessionHeader** (first line only):

```json
{
  "type": "session",
  "version": 3,
  "id": "<uuid>",
  "timestamp": "<ISO8601>",
  "cwd": "<absolute-path-to-working-dir>",
  "parentSession": "<optional-uuid>" | null
}
```

**Message entries** (type: `"message"`):

```json
{
  "type": "message",
  "id": "<unique-id>",
  "timestamp": "<ISO8601>",
  "role": "user" | "assistant" | "tool",
  "content": [
    { "type": "text", "text": "..." },
    { "type": "image", "mimeType": "...", "base64": "..." },
    { "type": "toolUse", "id": "...", "name": "...", "input": {...} },
    { "type": "toolResult", "toolUseId": "...", "content": [...] }
  ],
  "stopReason": "endTurn" | "toolUse" | "error" | "aborted",
  "errorMessage": "..." | null
}
```

**Other entries** (lowercase, with metadata):

- `"thinkingLevelChange"`: `{ level: "off" | "minimal" | ... }`
- `"modelChange"`: `{ provider, modelId }`
- `"compaction"`: `{ compactedLength: number, customInstructions: string }`
- `"branchSummary"`: `{ entryId, summary: string }`
- `"custom"`: user-defined; pass through as-is
- `"label"`: `{ entryId, label: string }`
- `"sessionInfo"`: `{ name?: string, ... }`

### 1.2 Migration chain

Upstream migrations (migrations.ts):

1. **Auth migration** (`migrateAuthToAuthJson`): `oauth.json` + `settings.json.apiKeys` → `auth.json`.
2. **Session root migration** (`migrateSessionsFromAgentRoot`): Move `.jsonl` files from `~/.pi/agent/*.jsonl` to correct `sessions/<encoded-cwd>/` subdirectories.
3. **Commands→prompts** (`migrateExtensionSystem`): Rename `commands/` to `prompts/`.
4. **Tool binaries** (`migrateToolsToBin`): Move `fd`/`rg` from `tools/` to `bin/`.

**OTP mapping**: Run migrations synchronously on startup in `OctoPi.Coder.CLI.main/1` before opening any sessions. Store already-migrated state in an ETS flag or a `.migrated_v3` marker file to avoid re-running.

### 1.3 Path encoding and directory structure

Session directory is computed as:

```elixir
def encode_cwd(cwd) do
  cwd
  |> String.replace(~r{^[/\\]}, "")      # strip leading / or \
  |> String.replace(~r{[/\\:]}, "-")    # replace /, \, : with -
  |> then(&"--#{&1}--")                 # wrap with --
end
```

Actual session file: `~/.pi/agent/sessions/<encoded-cwd>/<uuid>.jsonl`.

In Elixir, this maps to:

```elixir
defmodule OctoPi.Coder.SessionStore do
  def session_path(cwd, session_id) do
    encoded = encode_cwd(cwd)
    Path.join([agent_dir(), "sessions", encoded, "#{session_id}.jsonl"])
  end
end
```

### 1.4 Byte-level compatibility

- **No trailing whitespace** on lines.
- **Consistent key ordering** in JSON objects (not strictly required by JSON, but upstream uses object key iteration order):
  - `type`, `version` / `id`, `timestamp`, `cwd`, `parentSession` (header)
  - `type`, `id`, `timestamp`, `role`, `content`, `stopReason`, `errorMessage` (message)
- **LF line endings** (not CRLF).
- **UTF-8 encoding**, no BOM.

In Elixir, use `Jason.encode_to_iodata!/1` with the `order_keys: true` option (if Jason supports it), or manually construct the maps in order before encoding.

---

## 2. File mutation serialization

### 2.1 Design (file-mutation-queue.ts)

**Problem**: Concurrent writes to the same file can corrupt it. Solution: per-file queue.

**TS implementation**: A `Map<absolutePath, Promise<void>>` where each entry is a
chain of promises. When `withFileMutationQueue(path, fn)` is called:

1. Get the current queue promise for `path` (or `Promise.resolve()` if none).
2. Create a new promise that resolves only after `fn()` completes.
3. Chain it: `currentQueue.then(() => fn())`.
4. Store the new promise as the queue for `path`.
5. Await the current queue before running `fn()`.

**Key insight**: different paths run in parallel; same path serializes.

### 2.2 OTP mapping

**Option A: GenServer per path (preferred for clarity)**

```elixir
defmodule OctoPi.Coder.FileMutex do
  def lock(abs_path, fun) do
    case Registry.lookup(:octo_pi_file_mutex, abs_path) do
      [{pid, _}] ->
        GenServer.call(pid, {:run, fun}, :infinity)
      [] ->
        {:ok, pid} = DynamicSupervisor.start_child(
          OctoPi.Coder.FileMutex.Supervisor,
          {__MODULE__.Worker, abs_path}
        )
        GenServer.call(pid, {:run, fun}, :infinity)
    end
  end
end

defmodule OctoPi.Coder.FileMutex.Worker do
  use GenServer

  def init(path), do: {:ok, %{path: path}}

  def handle_call({:run, fun}, _from, state) do
    result = fun.()
    {:reply, result, state}
  end
end
```

Register paths in `Registry` (unique mode) so that multiple callers find the same worker.

**Option B: Single arbiter GenServer + Queue**

A single `FileMutex.Arbiter` holds a `%{path => queue}` map. On request, enqueue the fun and process serially. Simpler but slightly less concurrent (all locks go through one process).

**Recommendation: Option A**. Cleaner semantics, true parallelism across paths.

---

## 3. Core file tools

### 3.1 `read` tool

**Schema** (read.ts L17-21):

```typescript
{
  path: string,
  offset?: number,  // 1-indexed; line to start from
  limit?: number    // max lines to read
}
```

**Return shape** (content blocks + details):

```typescript
{
  content: TextContent[] | ImageContent[],
  details?: {
    truncation?: {
      truncated: boolean,
      truncatedBy: "lines" | "bytes",
      totalLines: number,
      outputLines: number,
      maxLines: number,
      maxBytes: number,
      firstLineExceedsLimit?: boolean
    }
  }
}
```

**Path resolution** (path-utils.ts):
- If relative: resolved against `cwd`.
- If absolute: used as-is.
- Symlinks resolved via `realpathSync.native()`.

**Error modes**:
- Permission denied: throw `EACCES` → caught by loop, returns error `ToolResultMessage`.
- File not found: throw `ENOENT` → error result.
- Image detection: uses MIME type lookup; non-image files treated as text.
- Truncation: files > 10,000 lines or > 512 KB are truncated; details include hint to use offset+limit.

**OTP shape**:

```elixir
defmodule OctoPi.Coder.Tools.Read do
  @behaviour OctoPi.Coder.Tool

  def name, do: "read"
  def schema, do: %{"type" => "object", "properties" => ...}

  def execute(_id, %{"path" => path, "offset" => offset, "limit" => limit}, _cwd) do
    abs_path = resolve_path(path, cwd)
    File.stream!(abs_path, [:read, :utf8])
    |> Stream.drop(max(0, offset - 1))
    |> Stream.take(limit || :infinity)
    |> Enum.join("\n")
    |> then(&{:ok, %Content.Text{text: &1}})
  rescue
    e -> {:error, Exception.message(e)}
  end
end
```

### 3.2 `write` tool

**Schema** (write.ts L14-17):

```typescript
{
  path: string,
  content: string
}
```

**Behavior**:
- Creates intermediate directories via `mkdir -p`.
- Overwrites file if exists.
- Wrapped in `withFileMutationQueue` (file-mutation-queue.ts L9).

**Return**: simple success message, no content block.

**OTP shape**:

```elixir
def execute(_id, %{"path" => path, "content" => content}, _cwd) do
  abs_path = resolve_path(path, cwd)
  OctoPi.Coder.FileMutex.lock(abs_path, fn ->
    abs_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(abs_path, content, [:write, :utf8])
  end)
  {:ok, %Content.Text{text: "Written #{byte_size(content)} bytes to #{Path.basename(abs_path)}"}}
rescue
  e -> {:error, Exception.message(e)}
end
```

### 3.3 `edit` tool

**Schema** (edit.ts L42-51):

```typescript
{
  path: string,
  edits: [
    { oldText: string, newText: string },
    ...
  ]
}
```

**Semantics**:
- Each `{ oldText, newText }` is a targeted replacement. `oldText` is matched *exactly* and must be unique in the file.
- Multiple edits in one call are applied atomically; if any fails, the whole operation fails.
- Edits are matched against the original file (not incrementally).
- Returns a unified diff of changes.

**Details**:

```typescript
{
  diff: string,  // unified diff
  firstChangedLine?: number
}
```

**Error modes**:
- `oldText` not found: error.
- `oldText` appears multiple times: error.
- Overlapping edits: error (caller's responsibility to merge).

**OTP mapping**: read file, apply edits sequentially (pattern matching per edit), compute diff, write back, all within `FileMutex.lock`.

### 3.4 `ls` tool (directory listing)

**Schema** (inferred from pi codebase):

```typescript
{
  path?: string  // directory to list (default: cwd)
}
```

**Return**: list of entries with `name`, `isDirectory`, `size`, `modified`, etc.

**OTP**: `File.ls!/1`, stat each entry, return as `TextContent`.

---

## 4. Bash tool

### 4.1 Streaming execution (bash.ts + bash-executor.ts)

**Schema** (bash.ts L33-36):

```typescript
{
  command: string,
  timeout?: number  // seconds; no default
}
```

**Execution flow** (bash-executor.ts):

1. Spawn `/bin/bash -c <command>` (or `cmd.exe` on Windows).
2. Stream `stdout + stderr` through an `onChunk` callback.
3. Maintain a rolling buffer (default 2×512 KB = 1 MB in-memory).
4. If output exceeds threshold, spill to a temp file.
5. On completion or abort, truncate to 512 KB or return truncation marker.

**Return**:

```typescript
{
  output: string,        // sanitized, possibly truncated
  exitCode: number | null,
  cancelled: boolean,
  truncated: boolean,
  fullOutputPath?: string
}
```

### 4.2 Process group termination (critical)

**TS**: Uses Node.js `child_process.spawn(…, { detached: true })` to spawn the shell
in its own process group. On abort, calls `killProcessTree(pid)` which sends `SIGTERM`
to the process group (`kill -TERM -$pgid`).

**OTP challenges**:
- `Port.open({:spawn_executable, shell}, opts)` can't signal process groups directly.
- Erlang has no native `kill -$pgid` (negative PID).
- Solutions:
  1. **Tiny C shim** (`erlexec` library): Erlang can exec a helper binary that does `kill -TERM -$pgid`.
  2. **NIF wrapper**: wrap POSIX `killpg(pgid, SIGTERM)`.
  3. **Rely on `:exit_status`**: let the process exit naturally on parent termination.

**Recommendation**: Use **`erlexec`** (hex.pm dependency). It provides `exec:manage/2` that:
- Spawns processes in new process groups.
- Can send signals to groups.
- Tracks child PIDs for cleanup on exit.

```elixir
defmodule OctoPi.Coder.Tools.Bash do
  def execute(_id, %{"command" => cmd}, cwd) do
    case exec:manage({cmd, [cwd: cwd]}) do
      {:ok, pid, child_pid} ->
        # Streaming would happen via message passing or a callback
        wait_for_output(child_pid)
        {:ok, %Content.Text{text: output}}
      {:error, reason} ->
        {:error, "Failed to execute: #{reason}"}
    end
  end

  defp on_abort(child_pid) do
    exec:stop(child_pid)  # sends SIGTERM to process group
  end
end
```

If `erlexec` is too heavy, fallback: port-spawn a small Go/Rust binary that wraps
`execvp` and signal handling, and speak to it over stdin/stdout.

### 4.3 Streaming to session

**TS**: `onChunk` callback is passed to `BashOperations.exec`. Each chunk is
emitted to `tool_execution_update` events.

**OTP**: The loop task (or tool task if tool is sequential) receives chunks via
messages. Option:

```elixir
def execute(_id, %{"command" => cmd}, _cwd, on_update) do
  {:ok, port} = exec_streaming(cmd, cwd, fn chunk ->
    on_update.({:chunk, chunk})  # or send back to loop
  end)
  await_port(port)
end
```

### 4.4 Env and stdin

**TS** (shell.js): `getShellEnv()` copies current process env, optionally patching it. No stdin forwarding; stdio[0] is "ignore".

**OTP**: Use `Port.open` with `[{:env, env_list}]`. No stdin by default.

---

## 5. Search tools (grep, find)

### 5.1 `grep` tool (grep.ts)

**Schema**:

```typescript
{
  pattern: string,
  path?: string,
  glob?: string,     // filter files to search
  ignoreCase?: boolean,
  literal?: boolean,
  context?: number,  // lines before/after match
  limit?: number     // max matches; default 100
}
```

**Implementation**: spawns `rg` (ripgrep) if available; falls back to spawning
`grep -r` in pure bash. Parses line-by-line output.

**OTP mapping**: `System.cmd/3` or `Port.open` to ripgrep/grep, parse JSONL-like output.

### 5.2 `find` tool (find.ts)

**Schema**:

```typescript
{
  pattern: string,   // glob like "*.ts" or "**/*.json"
  path?: string,     // directory; default "."
  limit?: number     // default 1000
}
```

**Implementation**: spawns `fd` (if available) or `find` command. Filters results by limit.

**OTP**: similar to grep; spawn process, read lines.

---

## 6. Print mode

### 6.1 Flow (print-mode.ts)

```
CLI args parsed
  → resolve mode (--print / --mode json / stdin)
  → build runtime
  → runPrintMode(runtime, { mode: "text" | "json", initialMessage, messages })
    → if JSON mode: emit SessionHeader + event lines to stdout
    → send initialMessage to session.prompt()
    → for each subsequent message: session.prompt()
    → if text mode: extract last assistant message, emit .text content to stdout
    → exit(0 or 1)
```

### 6.2 Output

- **Text mode**: plain text to stdout. On error, error message to stderr, exit(1).
- **JSON mode**: newline-delimited JSON; each line is a `{type: "...", ...}` event.
  Events include `agent_start`, `message_start/update/end`, `tool_execution_*`, `agent_end`.

### 6.3 Signal handling

Catches `SIGTERM` and `SIGHUP`, kills any tracked bash children, disposes runtime, exits.

**OTP shape**:

```elixir
defmodule OctoPi.Coder.Modes.Print do
  def run(session_pid, %{mode: mode, initial_message: msg, messages: msgs}) do
    # Subscribe to all events
    OctoPi.Agent.subscribe(session_pid, self(), :async)

    # If JSON mode, emit header first
    if mode == :json do
      IO.binwrite(Jason.encode!(session_header))
    end

    # Prompt
    OctoPi.Agent.prompt(session_pid, msg)
    for m <- msgs, do: OctoPi.Agent.prompt(session_pid, m)

    # Collect messages from subscriber
    receive_loop(mode)
  end

  defp receive_loop(mode) do
    receive do
      {:event, event} ->
        if mode == :json do
          IO.binwrite(Jason.encode!(event) <> "\n")
        end
        receive_loop(mode)
      {:agent_end, _} ->
        if mode == :text, do: emit_last_text()
        0
    end
  end
end
```

---

## 7. RPC mode

### 7.1 Protocol (rpc-types.ts, rpc-mode.ts)

**Format**: newline-delimited JSON on stdin (requests) and stdout (responses + events).

**Request** (RpcCommand, from stdin):

```json
{
  "id": "uuid-or-correlate-string",
  "type": "prompt" | "steer" | "follow_up" | "abort" | "get_state" | "set_model" | ...,
  "message": "...",
  "images": [...]
}
```

**Response** (RpcResponse, to stdout):

```json
{
  "id": "same-as-request",
  "type": "response",
  "command": "prompt",
  "success": true,
  "data": {...}
}
```

**Event** (streamed as requests arrive):

```json
{
  "type": "agent_start" | "turn_start" | "message_start" | "message_update" | "message_end" | "tool_execution_start" | ... | "agent_end",
  "sessionId": "...",
  ...
}
```

### 7.2 Correlation and streaming

- Each request has optional `id` field. Response echoes it. Allows pipelining requests and matching responses async.
- Events are emitted as they fire, not batched.
- If request has no `id`, response has no `id` either.

### 7.3 OTP mapping

```elixir
defmodule OctoPi.Coder.Modes.RPC do
  def run(session_pid) do
    take_over_stdout()

    # Subscribe to events
    OctoPi.Agent.subscribe(session_pid, self(), :async)

    # Read stdin line by line
    IO.stream(:stdio, :line)
    |> Stream.map(&Jason.decode!/1)
    |> Stream.each(&handle_command(&1, session_pid))
    |> Stream.run()

    # Should never return
    :error_io_closed
  end

  defp handle_command(cmd, session_pid) do
    case cmd["type"] do
      "prompt" ->
        OctoPi.Agent.prompt(session_pid, cmd["message"])
        reply(cmd["id"], :prompt, :ok)
      "get_state" ->
        state = OctoPi.Agent.state(session_pid)
        reply(cmd["id"], :get_state, :ok, state)
      "abort" ->
        OctoPi.Agent.abort(session_pid)
        reply(cmd["id"], :abort, :ok)
      _ ->
        reply(cmd["id"], cmd["type"], :error, "Unknown command")
    end
  end

  defp reply(id, command, status, data \\ nil) do
    resp = %{
      "id" => id,
      "type" => "response",
      "command" => command,
      "success" => status == :ok
    }
    resp = if data, do: Map.put(resp, "data", data), else: resp
    IO.binwrite(Jason.encode!(resp) <> "\n")
  end
end
```

**Stdin blocking**: `IO.stream(:stdio, :line)` is a `Stream`, which is lazy. When
we call `Stream.run()` on it, it blocks on reading. This is fine for RPC mode.

---

## 8. CLI entry

### 8.1 Args parsing (args.ts)

**Key flags**:
- `--print` / `-p`: enable print mode.
- `--mode json|rpc`: set output mode.
- `--session <id>`: load/resume session by ID or path.
- `--fork <id>`: create new session as fork of ID.
- `--provider` / `--model`: override AI provider/model.
- `--thinking <level>`: set reasoning level.
- `--system-prompt` / `--append-system-prompt`: customize instructions.
- `--tool`, `--extension`, `--skill`: load specific tools/extensions/skills.
- `--no-tools`, `--no-extensions`: disable.
- Extension flags (map of unknowns): `--unknownFlags`.

**Positional args**: treated as message text. `@filename` expands file content inline.

### 8.2 Main entry (main.ts)

Rough flow:

```
parseArgs(process.argv)
  → runMigrations(cwd)
  → resolve model + provider
  → resolve session (new or load)
  → create AgentSessionServices (tools, extensions, models, settings)
  → createAgentSessionRuntime (wraps the OctoPi.Agent.Session + SessionManager)
  → dispatch to mode:
      - "interactive" → InteractiveMode (Phase 4; TUI)
      - "print" → runPrintMode(runtime, options)
      - "json" → runPrintMode(runtime, {mode: "json"})
      - "rpc" → runRpcMode(runtime)
  → exit with code
```

### 8.3 OTP mapping

```elixir
defmodule OctoPi.Coder.CLI do
  def main(argv) do
    args = parse_args(argv)

    if args.help, do: print_help() and exit(0)
    if args.version, do: IO.puts("1.0.0") and exit(0)

    # Ensure app is started
    {:ok, _} = Application.ensure_all_started(:octo_pi_coder)

    # Run migrations
    run_migrations(args.cwd)

    # Build session
    {:ok, session_pid} = create_session(args)

    # Dispatch to mode
    exit_code = case resolve_mode(args) do
      :print -> OctoPi.Coder.Modes.Print.run(session_pid, mode: :text)
      :json -> OctoPi.Coder.Modes.Print.run(session_pid, mode: :json)
      :rpc -> OctoPi.Coder.Modes.RPC.run(session_pid)
      :interactive -> OctoPi.Coder.Modes.Interactive.run(session_pid)
    end

    exit(exit_code)
  end
end
```

---

## 9. OTP mapping for Phase 3

### 9.1 New app structure

Create a new umbrella app `octo_pi_coder` (or `octo_pi` as the single app with
namespaced modules). Proposed layout:

```
apps/octo_pi_coder/lib/octo_pi/coder/
  ├── cli.ex                   # CLI entry + mode dispatch
  ├── bootstrap.ex             # session builder
  ├── session_store.ex         # GenServer wrapping JSONL I/O
  ├── migrations.ex            # config/session/auth migrations
  ├── config.ex                # paths + constants
  ├── modes/
  │   ├── print.ex
  │   ├── rpc.ex
  │   └── interactive.ex       # Phase 4
  ├── tools/
  │   ├── read.ex
  │   ├── write.ex
  │   ├── edit.ex
  │   ├── bash.ex
  │   ├── grep.ex
  │   ├── find.ex
  │   ├── ls.ex
  │   └── file_mutex.ex
  ├── events/
  │   ├── dispatcher.ex        # fire-and-forget, gate, transform, etc.
  │   └── extension.ex         # @behaviour
  └── application.ex           # supervisor + app setup
```

### 9.2 Supervision tree addition

Extend the root `OctoPi.Application` to include:

```elixir
OctoPi.Application
├── (existing from Phase 2)
└── OctoPi.Coder.Supervisor
    ├── OctoPi.Coder.SessionStore        # stores active sessions
    ├── DynamicSupervisor (FileMutex)    # per-file locks
    ├── OctoPi.Coder.Events              # extension dispatcher (GenServer)
    ├── Task.Supervisor (Bash cleanup)   # monitors detached bash processes
    └── ETS tables:
        - :octo_pi_sessions (name → pid)
        - :octo_pi_file_mutex (path → pid)
        - :octo_pi_tools (tool registry)
```

### 9.3 Telemetry events

New events to emit:

- `[:octo_pi_coder, :session, :start]` — session created.
- `[:octo_pi_coder, :session, :save]` — entry appended to JSONL.
- `[:octo_pi_coder, :tool, :execute, :start]` — tool invoked.
- `[:octo_pi_coder, :tool, :execute, :complete]` — tool finished.
- `[:octo_pi_coder, :bash, :spawn]` — bash process started.
- `[:octo_pi_coder, :bash, :exit]` — bash process exited.

---

## 10. Hard parts — gotchas and critical decisions

### 10.1 Bash process group termination

**The problem**: On abort, the loop should kill the bash command and any children
it spawned. Node's `child_process` with `detached: true` gives a process group;
`kill -TERM -$pgid` works. Erlang has no direct equivalent.

**Solution**: Use `erlexec` (third-party, but well-maintained). It abstracts the
gnarly signal handling. Fallback: spawn a tiny shim binary (Go/Rust) that does
the killing and speak over a socket/stdin-pipe.

**Risk**: if erlexec is unmaintained or incompatible, we're stuck. Mitigation:
ship a minimal C shim as a NIF or separate binary.

### 10.2 Byte-compatible JSONL

**The problem**: Session files must be readable by upstream `pi` and vice versa.
Any change to the format (key order, encoding, field names) breaks compatibility.

**Solution**: never change the session schema. If extensions need to store data,
add new entry types (e.g., `custom` or `extensionData`), not new fields on
existing entries. Validate that we can parse upstream sessions without error.

**Test**: load a session file from upstream `pi` v0.69.0 and resume it.

### 10.3 File mutex under abort

**The problem**: if a tool is executing a write when `abort()` is called, the
write may partially complete, leaving the file in a corrupted state.

**Solution**: `Task.shutdown(tool_task, :brutal_kill)` kills the task immediately.
If the task is holding a FileMutex lock (waiting inside a GenServer.call), it
exits with `:killed`, releasing the lock. File corruption is still possible if
the OS doesn't fully flush before the process dies.

**Mitigation**: write to a temp file first, then atomic rename. Upstream doesn't
do this; we can patch it in Phase 3 without breaking JSONL format.

### 10.4 RPC stdin blocking

**The problem**: `IO.stream(:stdio, :line)` blocks the calling process. If we're
also subscribed to the session (to relay events), we need to handle both stdin
reads and event messages concurrently.

**Solution**: spawn a separate task to read stdin and forward commands to the
session. The main process listens for events and writes them.

```elixir
def run(session_pid) do
  # Task 1: read stdin, send commands
  {:ok, reader_task} = Task.start_link(fn -> read_stdin_loop(session_pid) end)

  # Task 2: main, listen for events and write them
  OctoPi.Agent.subscribe(session_pid, self(), :async)
  event_loop()
end

defp read_stdin_loop(session_pid) do
  IO.stream(:stdio, :line)
  |> Stream.map(&Jason.decode!/1)
  |> Stream.each(&handle_command(&1, session_pid))
  |> Stream.run()
end
```

### 10.5 Streaming output truncation

**The problem**: bash output can be huge (100 MB logs). We can't keep it all in
RAM or relay it all to the LLM.

**Solution**: truncate to 512 KB (DEFAULT_MAX_BYTES) and spill excess to a temp
file. Pass `fullOutputPath` to the tool result so the extension system can
decide what to do (show a link, compress, upload, etc.).

### 10.6 Path resolution edge cases

**The problem**: symlinks, relative paths, and cwd changes can confuse path
resolution.

**Solution**: always resolve to an absolute path via `Path.expand(path, cwd)`.
For file mutex keys, use `File.stat!()` to get the inode (on POSIX systems),
which is immune to symlinks. On Windows, use the canonical path.

---

## 11. Critical path for Print + RPC (Phase 3)

Things that **must** ship:

1. **Session JSONL store** — read/write with byte-compatibility.
2. **File tools** (read, write, edit) — working mutations via FileMutex.
3. **Bash tool** — streaming output, timeout, abort/kill-group semantics.
4. **Print mode** — text and JSON output to stdout.
5. **RPC mode** — stdin/stdout JSON line protocol.
6. **CLI dispatch** — args → mode selection.

Things that **can defer** to Phase 4 or later:

- Interactive TUI (moved to Phase 4).
- Compaction (mentioned in RESEARCH.md but not on the critical path).
- Extensions system (20+ event types; Phase 6).
- Export-HTML (nice-to-have).
- Multi-auth (OAuth, API keys; Phase 8).
- Shell search tools (grep, find) — can stub as errors for now.
- Thinking level, model selection — stub in session state, defer UI.

---

## 12. Tests to port

From `tmp/pi-mono/packages/coding-agent/test/`:

### Session JSONL

- Round-trip a session file (write, read, verify structure).
- Migrate session from old location.
- Fork session (copy file, rewrite parentSession).

### File tools

- `read`: basic read, offset+limit, image detection, truncation marker.
- `write`: create dirs, overwrite, mutate queue.
- `edit`: apply edits, compute diff, fail on overlaps.

### Bash

- Execute simple command, capture output.
- Abort mid-stream (kill process group).
- Truncate large output.
- Timeout semantics.

### Print mode

- Text output: last message is extracted.
- JSON mode: events streamed as JSONL.
- Exit code on error.

### RPC mode

- Request/response correlation.
- Prompt command, get events.
- Abort command.
- Concurrent requests (pipelined).

---

## 13. Dependencies (hex.pm)

New for Phase 3:

- **`erlexec`** — process group management + signal handling.
- **`exqlite`** (optional) — SQLite session store (for high concurrency; v1 JSONL is fine).
- **`req`** — already in Phase 1; reuse.

Existing from Phase 1/2:

- **`jason`** — JSON parsing.
- **`nimble_parsec`** — parsing helpers (optional).

---

## Appendix: File references

Line citations into `tmp/pi-mono/packages/coding-agent/`:

- **migrations.ts** L20–314 — all migrations
- **agent-session.ts** — session state (read via grep; file is 41K)
- **file-mutation-queue.ts** L19–39 — queue design
- **read.ts** L17–150 — read tool
- **write.ts** L14–100 — write tool  
- **edit.ts** L31–150 — edit tool (edits schema)
- **bash.ts** L33–150 — bash tool
- **bash-executor.ts** L1–150 — executor impl
- **grep.ts** L23–80 — grep tool
- **find.ts** L20–80 — find tool
- **print-mode.ts** L1–150 — print flow
- **rpc-types.ts** L1–100 — RPC protocol
- **rpc-mode.ts** L1–150 — RPC mode handler
- **args.ts** L1–150 — CLI parsing
- **main.ts** L1–150 — main entry
