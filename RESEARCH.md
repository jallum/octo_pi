# octo_pi: Porting `pi-mono` to Elixir/OTP — Research Report

> **Status:** Research mode. Source repo shallow-cloned to `tmp/pi-mono` (git-ignored). Version inspected: v0.69.0.

## Contents

1. [Upstream: what is `pi-mono`?](#1-upstream-what-is-pi-mono)
2. [The seven packages at a glance](#2-the-seven-packages-at-a-glance)
3. [Per-package architecture + OTP mapping](#3-per-package-architecture--otp-mapping)
   - 3.1 `pi-ai` → `OctoPi.AI`
   - 3.2 `pi-agent-core` → `OctoPi.Agent`
   - 3.3 `pi-coding-agent` → `OctoPi.Coder`
   - 3.4 `pi-tui` → `OctoPi.TUI`
   - 3.5 `pi-mom`, `pi-pods`, `pi-web-ui`
4. [Cross-cutting OTP design decisions](#4-cross-cutting-otp-design-decisions)
5. [Proposed supervision tree](#5-proposed-supervision-tree)
6. [Phased porting roadmap](#6-phased-porting-roadmap)
7. [Open questions & unresolved trade-offs](#7-open-questions--unresolved-trade-offs)
8. [Deep dives (control flow, renderer, extensions)](#8-deep-dives)

---

## 1. Upstream: what is `pi-mono`?

`pi-mono` (by Mario Zechner, MIT-licensed) is a TypeScript monorepo for building and operating AI coding agents. It ships:

- a **unified LLM abstraction** over 20+ providers (Anthropic, OpenAI, Google, Bedrock, Mistral, …),
- a **general-purpose agent runtime** (stream → tool call → result → repeat),
- an **interactive coding-agent CLI** (`pi`) with filesystem/bash/edit tools and persistent JSONL sessions,
- a **terminal UI library** with differential rendering (flicker-free updates via CSI 2026),
- a **Slack bot** (`mom`), a **vLLM deployment CLI** (`pods`), and a **web-components chat UI**.

Total source: ~**106K LOC TypeScript** across 7 packages. Primary distributed artifact: the `pi` binary (44K LOC coding-agent) built against the core libraries.

Our goal: re-express the four core packages (`ai`, `agent`, `coding-agent`, `tui`) on the BEAM so that the resulting `octo_pi` is a first-class Elixir/OTP citizen — supervised, concurrent, distribution-ready, and hot-reloadable. The periphery (`mom`, `pods`, `web-ui`) informs the design but is not all on the critical path.

---

## 2. The seven packages at a glance

| Package (npm name)                | Dir              | LOC    | Role                                                       | Depends on                        |
|-----------------------------------|------------------|-------:|------------------------------------------------------------|-----------------------------------|
| **pi-ai** (`@mariozechner/pi-ai`) | `packages/ai`           | 28,743 | Multi-provider LLM API, streaming, tool schemas, OAuth     | provider SDKs, typebox            |
| **pi-agent-core** (`pi-agent-core`) | `packages/agent`      |  1,965 | Stateful agent loop, tool orchestration, transport pluggable | `pi-ai`                         |
| **pi-coding-agent** (`pi-coding-agent`) | `packages/coding-agent` | 44,015 | `pi` CLI: REPL/Print/RPC modes, tools, sessions, hooks | `pi-ai`, `pi-agent-core`, `pi-tui` |
| **pi-tui** (`pi-tui`)             | `packages/tui`          | 10,995 | Differential-rendering TUI library                         | `chalk`, `get-east-asian-width`   |
| **pi-web-ui** (`pi-web-ui`)       | `packages/web-ui`       | 14,670 | Lit web-components chat UI + artifact sandboxes            | `pi-ai`, `pi-tui`                 |
| **pi-mom** (`pi-mom`)             | `packages/mom`          |  4,135 | Slack socket bot delegating to coding-agent                | all three core packages           |
| **pi-pods** (`@mariozechner/pi`)  | `packages/pods`         |  1,773 | vLLM GPU-pod SSH orchestration CLI                         | —                                 |

Key observation: the **lower three layers (`ai` → `agent-core` → `coding-agent`) form a linear stack**. Everything user-facing (TUI, Slack bot, web UI) sits on top. That's the porting strategy backbone.

---

## 3. Per-package architecture + OTP mapping

### 3.1 `pi-ai` → `OctoPi.AI` (the provider layer)

**What it does.** Single facade — `stream(model, context, options)` returning an `AssistantMessageEventStream` — wrapping 10+ provider implementations (`anthropic-messages`, `openai-responses`, `google-generative-ai`, `bedrock-converse-stream`, …). The stream emits a canonical event union: `start`, `text_delta`, `thinking_delta`, `toolcall_delta`, `toolcall_end` (with `ToolCall`), `done`, `error`. Providers are lazy-loaded modules registered in a global registry (`api-registry.ts`). Tool schemas are defined with **typebox** (runtime-inspectable JSON Schema). Message normalization handles per-provider quirks (Anthropic tool-id regex, thinking block coercion, image downgrade for non-vision models). Auth spans env vars, OAuth (Anthropic, GitHub Copilot, Gemini CLI, OpenAI Codex), and AWS creds for Bedrock.

**Core types** (`packages/ai/src/types.ts`):

```ts
type KnownApi = "openai-completions" | "anthropic-messages" | ...
interface Context { systemPrompt?: string; messages: Message[]; tools?: Tool[] }
type AssistantMessageEvent =
  | {type:"start", partial}
  | {type:"text_delta", contentIndex, delta, partial}
  | {type:"toolcall_end", contentIndex, toolCall, partial}
  | {type:"done", reason, message}
  | {type:"error", reason, error}
```

**OTP mapping.**

| TS concept                              | Elixir/OTP                                                                 |
|-----------------------------------------|----------------------------------------------------------------------------|
| `Api` union + `ApiProvider` interface   | `@behaviour OctoPi.AI.Provider` with `stream/3`, `stream_simple/3`         |
| `registerApiProvider`, global map       | ETS table `:octo_pi_providers` populated at app start; behaviour dispatch  |
| `AssistantMessageEventStream` (async iter + backpressure queue) | Elixir `Stream` produced from a `GenServer`-owned mailbox; **GenStage** if consumers need explicit demand |
| Per-provider SDKs (openai, @anthropic-ai/sdk, …) | Single HTTP client (`Req` or `Finch`) + per-provider request/response codec modules |
| typebox schemas                         | Tool params as plain maps validated with **`Peri`** or `Norm`; we do *not* need compile-time types at runtime |
| `parseStreamingJson` (partial-json lib) | Port verbatim as a small pure module over binaries; Elixir pattern matching makes this straightforward |
| OAuth flows (`oauth.ts`)                | `OctoPi.AI.OAuth` module; credentials cache in ETS + Dets for persistence |
| `sessionId`/cache retention headers     | Plug-through options in `%OctoPi.AI.StreamOptions{}` struct               |
| `AbortSignal`                           | Caller passes a ref; producer monitors it and halts the stream             |

**Recommended shape.** Stateless module functions (`OctoPi.AI.stream/3`) that **spawn an unnamed `GenServer`** per call. That GenServer opens the upstream HTTP request with `Req.get(..., into: :self)` (or Finch streaming), decodes SSE chunks, and emits events as messages to the caller. A thin `Stream.resource/3` wrapper on the caller side turns those messages into an idiomatic Elixir `Stream`. Providers = behaviour modules. No long-lived processes per provider.

**Gotchas to watch.** The streaming tool-argument JSON is best-effort-parsed on every delta — we need `parse_streaming_json/1` that tolerates unterminated strings. Anthropic's tool-call-id regex (`^[a-zA-Z0-9_-]+$`) vs OpenAI Responses' 450-char `|`-containing IDs is a real normalization bug source. Bedrock's multiple auth modes (profile / static creds / bearer / ECS / IRSA) require a credential-provider chain module. OAuth flows run a local HTTP listener on a random port; in Elixir that's a mini `Plug.Cowboy` or `Bandit` child spec, lifecycle-managed.

---

### 3.2 `pi-agent-core` → `OctoPi.Agent` (the kernel)

**What it does.** Only ~2K LOC but architecturally the hottest code: the stateful agent loop. `Agent` (the class) wraps a mutable `AgentState` (`systemPrompt`, `model`, `thinkingLevel`, `tools`, `messages`, `isStreaming`, `pendingToolCalls`, `errorMessage`). The user calls `agent.prompt(text)` / `.continue()` / `.steer()` / `.followUp()` / `.abort()`. Internally `runAgentLoop()` executes two nested `while` loops:

- **Inner loop** — stream from LLM → parse events → if the stop reason is `toolUse`, dispatch all tool calls (parallel by default, sequential if any tool opts in) → append tool-result messages → repeat until no more tool calls.
- **Outer loop** — after the inner loop terminates, drain any queued `steer` or `followUp` messages and re-enter.

Events are emitted through an `AgentEventStream` (queue-based async iterator, inherits from pi-ai's `EventStream`): `agent_start`, `turn_start`, `message_start/update/end`, `tool_execution_start/update/end`, `turn_end`, `agent_end`, `error`. Transport is pluggable via a `streamFn` option (default: `pi-ai.streamSimple`; alternative: `streamProxy` which tunnels through an HTTP backend and reconstructs `partial` messages client-side). Tool execution honors `AbortSignal` and carries an `onUpdate(partialResult)` callback that lets tools stream progress.

**OTP mapping.** This is where OTP really pays off. The proposed shape:

```elixir
# Each agent session = one supervised GenServer
defmodule OctoPi.Agent.Session do
  use GenServer
  # state: %{messages, tools, model, subscribers, run_task, run_ref, steer_queue, follow_up_queue}

  def prompt(pid, input),  do: GenServer.call(pid, {:prompt, input}, :infinity)
  def steer(pid, msg),     do: GenServer.cast(pid, {:steer, msg})
  def follow_up(pid, msg), do: GenServer.cast(pid, {:follow_up, msg})
  def abort(pid),          do: GenServer.call(pid, :abort)
  def subscribe(pid),      do: GenServer.call(pid, {:subscribe, self()})
end
```

The inner loop runs as a **supervised `Task`** linked to the Session. Tool execution uses **`Task.async_stream`** with `max_concurrency: :infinity` for parallel tools and `1` for sequential. Cancellation = `Task.shutdown(task, :brutal_kill)` which propagates via `:EXIT` into running tool tasks (they're linked). `AbortSignal` semantics map cleanly: the loop task's `Process.monitor` on the session GenServer plus a shared `:ets` or `:persistent_term` cancellation flag checked at safe points.

Event emission = broadcasting to subscriber PIDs. Use **`Phoenix.PubSub`** (even without Phoenix the web framework — just the PubSub lib) or a plain subscriber list — both are fine at the scales we care about. `PubSub` gets us distribution for free.

| TS concept                                           | OTP primitive                                                         |
|------------------------------------------------------|-----------------------------------------------------------------------|
| `Agent` class (mutable state, event listeners)       | `GenServer` per session                                               |
| `runAgentLoop()` (long-running async function)       | `Task.Supervisor`-spawned task, linked to Session                     |
| `streamFn` transport abstraction                     | `@behaviour OctoPi.Agent.Transport` (impls: `Direct`, `Proxy`)        |
| Parallel tool execution (`Promise.all`)              | `Task.async_stream(tools, &execute/1, ordered: false)`                |
| `AbortController.signal`                             | Cancellation token: `:ets` flag + `Process.monitor`                   |
| Tool `onUpdate` callback                             | Tool task sends `{:tool_update, id, partial}` → forwarded to subscribers |
| `AgentToolResult.terminate` flag                     | Same semantic; short-circuits the loop                                |
| Event listener "barrier" (await all before next step) | `GenServer.call`/monitored `send` + ack if we care; otherwise cast   |

**Gotchas.** The listener-barrier semantics (TS awaits all listener promises before proceeding to the next loop step) don't have a free OTP equivalent. For most UI updates we don't care (fire-and-forget cast). For cancellable hooks (e.g., `session_before_compact`), we need request/reply via `GenServer.call` to each subscriber — or a mini voting protocol. Likely YAGNI until we port the hooks system.

---

### 3.3 `pi-coding-agent` → `OctoPi.Coder` (the application)

**What it does.** The `pi` binary: interactive coding assistant. Entry (`cli.ts` → `main.ts`) parses args, runs migrations, builds a `SessionManager` (session = JSONL file at `~/.pi/agent/sessions/--<encoded-cwd>--/<uuid>.jsonl`), constructs an `Agent` with coding tools, and enters one of four modes:

- **Interactive (TUI)** — rich editor + assistant streaming + session tree navigation,
- **Print** — single-shot prompt/response, optional JSON event stream,
- **RPC** — headless JSON-lines stdin/stdout protocol,
- **SDK** — direct library use.

**Tools** (`packages/coding-agent/src/core/tools/`): `read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`. Each has a typebox schema, an execute handler, and optional TUI renderers (`renderCall`, `renderResult`). Bash spawns `/bin/bash` with `detached: true`, streams stdout/stderr through a rolling 2MB buffer, spills overflow to a temp file, tracks child PIDs so SIGTERM cleans them up. File mutations (`write`, `edit`) serialize via a `proper-lockfile`-backed per-file mutex (`file-mutation-queue.ts`).

**Extensions system** (`packages/coding-agent/src/core/extensions/`) — the big surprise. What the AGENTS.md called "hooks" is really a rich **event bus** with 20+ lifecycle points: `session_start`, `session_before_switch` (cancelable), `session_before_compact` (with `CompactionPreparation` payload), `before_agent_start`, `context` (mutate messages), `before_provider_request` (replace payload), `after_provider_response`, `tool_call` (mutate input), `tool_result` (mutate output), `user_bash` (handle `!cmd` prefix), `input` (transform user input), plus UI `message_*` events. Extensions can also register bash `spawnHook` to rewrite command context. This is a plugin architecture, not a handful of hooks.

**Sessions.** JSONL files, one line per entry. First line is a `SessionHeader` (`{type:"session", version, id, timestamp, cwd, parentSession?}`). Remaining entries are typed: `message`, `thinkingLevelChange`, `modelChange`, `compaction`, `branchSummary`, `custom`, `customMessage`, `label`, `sessionInfo`. Sessions form a **tree** (fork support via `--fork <id>`). Append is atomic via `fs.appendFileSync`.

**OTP mapping.**

```elixir
# escript/Burrito entry
OctoPi.Coder.CLI.main(argv) ->
  OctoPi.Coder.Bootstrap.build_runtime(argv) ->
    - OctoPi.Coder.SessionStore (GenServer over JSONL file)
    - OctoPi.Coder.ExtensionRunner (event bus)
    - OctoPi.Agent.Session (from 3.2) configured with coding tools
    - mode dispatch -> Interactive|Print|Rpc
```

| pi-coding-agent concept               | OctoPi.Coder                                                            |
|---------------------------------------|-------------------------------------------------------------------------|
| `cli.ts` / `main.ts`                  | `OctoPi.Coder.CLI` via **Mix escript** (or Burrito for a static binary) |
| `SessionManager` (JSONL reader/writer, tree, fork) | `OctoPi.Coder.SessionStore` GenServer; JSONL stays the on-disk format for cross-version compatibility with upstream `pi` |
| Tool definitions (typebox schemas + handlers) | `@behaviour OctoPi.Coder.Tool` with `name/0`, `schema/0`, `execute/3`; tools are modules registered in `:tools` table |
| `bash.ts` (detached child + streaming)       | `Port.open({:spawn_executable, shell}, [:binary, :exit_status, :stderr_to_stdout, :stream])` with a companion monitor that kills the OS pgid on session exit |
| File mutation mutex (`proper-lockfile`)      | Per-path `GenServer` via `Registry`; serializes write/edit on the same absolute path |
| Extension runner (20+ lifecycle events)      | `OctoPi.Coder.Events` dispatcher + `@behaviour OctoPi.Coder.Extension` implementing the callbacks an extension cares about; event dispatch supports return-value chaining (context transforms, cancels) |
| `!bash` prefix handling                      | `user_input` event; built-in extension that intercepts and calls bash tool directly |
| Print mode                                    | Straight `IO.puts` loop; same JSON schema |
| RPC mode (JSON-lines stdin/stdout)            | `IO.stream(:stdio, :line)` + `Jason` + supervised request handler |
| Interactive mode                              | Drives `OctoPi.TUI` (see 3.4) |
| Session fork / tree navigation                | Copy the file + rewrite `parentSession`; navigation is a read-only tree query on entries |
| `.pi` config dir + `~/.pi/agent/`             | `OctoPi.Coder.Config` module; respect `XDG_CONFIG_HOME` |

**Critical port decisions.**

- **Session file format stays JSONL v3** (matching pi-mono v0.69). This lets Elixir `octo_pi` and upstream `pi` read each other's sessions — huge for validation and for users who want to switch.
- **Bash is a `Port`, not `System.cmd`.** `System.cmd` is synchronous and can't stream. `Port` gives us `{:data, line}` messages and `{:exit_status, code}` for free. Kill-on-abort uses `:erlang.port_close/1` plus `kill -TERM -$pgid` via a small shim (Elixir can't signal a process group directly without a NIF or a `Port.command` to a shim).
- **Tool schemas**: I'd avoid typebox-style runtime JSON Schema authoring. Instead, define tool params as plain structs and generate the JSON Schema for the LLM from the struct plus module attributes. `Peri` or `Norm` cover validation.

**Gotchas.** Signal handling on BEAM is limited; we may need a NIF or a tiny C shim for robust process-group termination on macOS/Linux. Raw terminal mode for the Interactive TUI is even trickier (see 3.4). The permission-prompt pattern (`readline.question()` blocking) must not block the BEAM scheduler — it's a `GenServer.call` back to the TUI owner, not a tight loop on `IO.gets`.

---

### 3.4 `pi-tui` → `OctoPi.TUI` (the renderer)

**What it does.** A ~11K-LOC differential-rendering TUI. Each tick: components emit `string[]`, the renderer diffs against the previous frame line-by-line to find `firstChanged` / `lastChanged`, then moves the cursor and reprints only those lines — all wrapped in CSI 2026 (`\x1b[?2026h` / `\x1b[?2026l`) for atomic updates. Supports overlays, Kitty keyboard protocol (CSI u sequences), bracketed paste, SIGWINCH, Kitty/iTerm2 inline images, wide-char width lookup via `get-east-asian-width`. Components are stateful objects with `render(width) → string[]`, `handleInput(data)`, `invalidate()`. Editor component (76K of that 11K *is* the editor — kill ring, undo stack, slash-command / file-path autocomplete, fuzzy matching, multi-line wrap).

**Port vs. adopt.** The two main options:

1. **Adopt** `owl` or `ratatouille`. Owl is immediate-mode and unmaintained-ish for complex UIs. Ratatouille hasn't seen work in years. Neither does differential rendering or CSI 2026. We'd lose flicker-free semantics.
2. **Port natively.** Keep the differential-rendering core; rewrite key parsing as Elixir binary pattern matching (which is *dramatically* cleaner than TS regex); reuse immutable lists for `UndoStack` and `KillRing` (free structural sharing — no `structuredClone` needed).

**Recommendation: port natively.** The differential renderer is ~400 lines in Elixir. Key parsing shrinks from the ~700-line TS version to ~200 lines with binary patterns. The Editor is the bulk of the work (~1500 lines Elixir, down from 76K TS). Total estimated: **~3.5K Elixir LOC** — a fraction of the TS original.

**OTP shape.**

```elixir
OctoPi.TUI.Terminal  # Port over /dev/tty; raw mode via `stty` spawn; SIGWINCH via :os.set_signal
OctoPi.TUI.Renderer  # GenServer owning previous_lines, previous_width, previous_height; handle_cast({:render, lines})
OctoPi.TUI.Keys      # pure module; parse_key(binary) -> {:char, "a"} | {:key, :up, mods} | :paste_start | ...
OctoPi.TUI.Component # @behaviour: render/2, handle_input/2, invalidate/1
OctoPi.TUI.Editor    # concrete component
```

**Gotchas.** Raw-mode stdin on BEAM is not straightforward. `:stdio` is line-buffered and cooked by default. The realistic options are:

- Open `/dev/tty` directly as a file via a Port (works on Linux/macOS; Windows needs a different story).
- Shell out to `stty raw -echo` at boot and restore on shutdown (the approach most Erlang TUI libs take).
- Write a tiny `termios`-wrapping NIF (more work, but the gold standard).

SIGWINCH: `:os.set_signal(:sigwinch, :handle)` then match `{:signal, :sigwinch}`. Kitty protocol query: send `\x1b[?u`, parse reply — a small state machine in the Renderer.

---

### 3.5 The periphery: `pi-mom`, `pi-pods`, `pi-web-ui`

| Pkg      | Port priority | Target shape                                                                     |
|----------|---------------|----------------------------------------------------------------------------------|
| **mom**  | **High**, but late | Supervised OTP app. `OctoPi.Mom.Socket` = Slack socket GenServer. One `ChannelQueue` GenServer per channel (serialize work per channel). Re-uses `OctoPi.Agent.Session` for each thread. Streaming replies map directly to OTP message passing. Slack libraries for Elixir: `slax`, `slack_elixir`, or hand-roll over WebSockex — all viable. |
| **pods** | **Skip.** | Stateless SSH-orchestration CLI. Nothing here benefits from OTP. Keep upstream, or rewrite in Python/Bash if we need to own it. |
| **web-ui** | **Medium**, parallel track | **Not a direct port.** Rewrite as Phoenix LiveView. Chat panel, message renderers, artifact viewers, sandbox iframes all fit the LiveView model better than Lit web components. Storage migrates from IndexedDB to Ecto + Postgres (or SQLite via Exqlite). Keep artifact sandboxing out of BEAM — delegate to a small Node/Deno service. |

---

## 4. Cross-cutting OTP design decisions

These decisions apply across multiple octo_pi apps. Calling them out explicitly because they're the high-leverage choices.

### 4.1 Streaming: plain `Stream` vs. `GenStage`

pi-ai's `AssistantMessageEventStream` is an async iterator with an in-memory queue that grows if the consumer is slow. Real backpressure isn't implemented (the producer never stalls on a full queue).

**Recommendation: plain `Stream.resource/3` over a producer GenServer.** That gives us idiomatic consumption (`Enum.each`, `Stream.filter`, pipeline into Broadway for batch use cases) without the GenStage complexity. If we later discover a need for demand-driven backpressure (e.g., to throttle expensive tool calls), add a GenStage layer at that boundary — the event semantics don't change.

### 4.2 HTTP client

**Use `Req`** (built on Finch). `Req` has first-class streaming via `into: self()` and good middleware ergonomics. Avoid Tesla + Hackney for the async story. Finch connection pools per provider host.

### 4.3 Tool / message schema validation

Typebox gives pi a single source of truth for runtime validation + JSON Schema export. Elixir doesn't have a drop-in. Options:

- **`Peri`** — lightweight schema library; looks most typebox-like.
- **`Norm`** — spec-first, runtime-only.
- **Plain structs + a `to_json_schema/0` callback per tool** (we control what we send to the LLM).

**Recommendation**: plain structs plus `@behaviour OctoPi.Coder.Tool` with a `schema/0` callback that returns a JSON-Schema map. Validation via `Peri` if we find the pattern repetitive enough to warrant. Deliberately avoid a dependency on a complex validator in the hot path.

### 4.4 Session persistence

**Keep JSONL.** Same format as upstream `pi` — makes it trivial to:

- debug against upstream,
- share session recordings (the project publishes these to Hugging Face),
- swap clients without migrating.

The `SessionStore` GenServer wraps append operations. Reads are `File.stream!/1 |> Stream.map(&Jason.decode!/1)`. For high-concurrency scenarios (unlikely in a single-user CLI), we can revisit with SQLite + Exqlite.

### 4.5 Cancellation model

The JS ecosystem's `AbortSignal` is a pain to port faithfully because it's cooperative and lossy. The BEAM's `Process.monitor` / linking is stricter and more reliable.

**Pattern**: every long-running operation (LLM stream, tool exec) runs as a `Task` linked to its Session GenServer. "Abort" = `Task.shutdown(task, :brutal_kill)`. Linked tool tasks die transitively. Bash's OS-level children are killed by the port owner in its terminate callback.

### 4.6 Extensions / hooks system

Upstream has 20+ event types, many with mutable / cancelable payloads. The tempting shortcut is `Phoenix.PubSub` for broadcast — but that's fire-and-forget, which breaks hooks that need to transform or cancel.

**Design**: `OctoPi.Coder.Events.emit/2` is a synchronous reduce over registered extensions, each implementing a behaviour callback. Extensions that return `{:cont, new_payload}` transform the payload; `:halt` cancels. For fire-and-forget events (UI notifications), we also expose a `broadcast/2` that does PubSub and is cheap.

### 4.7 Distribution (optional, later)

Nothing here *requires* multi-node. But agent sessions as GenServers trivially become distributable if we want. Worth not foreclosing:

- Use `Registry` + `{:via, Registry, ...}` naming from day one — makes a future move to `Horde.Registry` or `:syn` painless.
- Avoid storing PIDs in on-disk state (always resolve by name / session-id).

---

## 5. Proposed supervision tree

```
OctoPi.Application
├── Finch (:octo_pi_finch)                     # HTTP pool
├── Registry (:octo_pi_sessions, unique)        # session-id -> pid
├── Registry (:octo_pi_file_mutex, unique)      # absolute path -> lock pid
├── Phoenix.PubSub (:octo_pi_pubsub)            # for events, subscribers
├── OctoPi.AI.Supervisor
│   ├── OctoPi.AI.ProviderRegistry (ETS owner)
│   └── OctoPi.AI.OAuth.Supervisor              # listener started on demand
├── OctoPi.Agent.SessionSupervisor (DynamicSupervisor)
│   └── OctoPi.Agent.Session (one per running session)
│        └── Task.Supervisor (for the loop + tool tasks)
├── OctoPi.Coder.Supervisor
│   ├── OctoPi.Coder.SessionStore.Manager      # owns session dir watcher
│   ├── OctoPi.Coder.Events                    # extension dispatch
│   └── OctoPi.Coder.Tools.Bash.ChildMonitor   # cleans up leaked OS children on shutdown
└── OctoPi.TUI.Supervisor (started only in Interactive mode)
    ├── OctoPi.TUI.Terminal (Port owner)
    └── OctoPi.TUI.Renderer (GenServer)
```

`OctoPi.Coder.CLI.main/1` builds the argv-derived config, starts the app if not already running, and either:

- blocks on a `Task.await` for Print/Rpc modes, or
- hands control to the TUI loop for Interactive mode.

Extensions are discovered at boot (config + auto-registered modules implementing `OctoPi.Coder.Extension`) and hang off `OctoPi.Coder.Events`.

---

## 6. Phased porting roadmap

Rough ordering. Each phase is a working deliverable — we don't wait for the whole stack before integrating.

**Phase 0 — Project scaffolding.** `mix new octo_pi --sup` as an umbrella with the four core apps (`octo_pi_ai`, `octo_pi_agent`, `octo_pi_coder`, `octo_pi_tui`). CI, `mix format`, `credo`, `dialyzer`.

**Phase 1 — `octo_pi_ai` against Anthropic only.** Provider behaviour + Anthropic impl + canonical event stream + tool-arg streaming JSON parser. End-state: a mix task that runs a single prompt through Anthropic end-to-end and streams deltas to stdout. Validates the stream + codec model.

**Phase 2 — `octo_pi_agent`.** Session GenServer, loop task, tool behaviour, `Task.async_stream` tool dispatch, cancellation via `Task.shutdown`. End-state: a trivial `Echo` tool and an in-process test driver running the full inner/outer loop.

**Phase 3 — `octo_pi_coder` (minus TUI).** Session JSONL store, migrations, built-in tools (`read`, `write`, `edit`, `bash`, `grep`, `find`, `ls`), Print and Rpc modes. End-state: `mix pi --print "…"` works against a real Anthropic model; `mix pi --mode rpc` passes a JSON round-trip test. Compatibility check: load a session file produced by upstream `pi` and resume it.

**Phase 4 — `octo_pi_tui` + Interactive mode.** Raw-mode Port, differential renderer, key parser, minimal Editor, SelectList. Integrate with coder as Interactive mode. Skip advanced editor features (autocomplete, undo coalescing) initially; land them incrementally.

**Phase 5 — More providers.** OpenAI Responses, Google, then Bedrock (most complex auth). Each adds a codec module; no agent-side changes.

**Phase 6 — Extensions system.** Port the hook/event model. Unlock custom tool injection and prompt transforms.

**Phase 7 — `octo_pi_mom`.** Slack bot as a separate app consuming `octo_pi_agent`. High-value: first "not a CLI" consumer of the stack.

**(Parallel) Phase W — `octo_pi_web`.** Phoenix + LiveView chat UI. Depends on `octo_pi_ai` + `octo_pi_agent` but not on `coder` or `tui`. Can be started any time after Phase 2.

**Phase 8 — OAuth + multi-auth polish + cost tracking + compaction.** Mostly mechanical once the skeleton is proven.

**Phase X — Explicitly deferred / declined.**

- `pi-pods` — not porting.
- Native typebox-equivalent — not building one.
- Windows support — out of scope for v1.

---

## 7. Open questions & unresolved trade-offs

Things to decide with the team before Phase 1 ships.

1. ~~**Umbrella vs. single app with namespaces?**~~ **Resolved 2026-04-23 (ticket `octo-w29.1`): umbrella**, four apps to start (`octo_pi_ai`, `octo_pi_agent`, `octo_pi_coder`, `octo_pi_tui`). Peripheral apps (`octo_pi_mom`, future `octo_pi_web`) added lazily when their phase starts. Rationale: structural decomposition matches upstream's linear `ai → agent → coder` dep chain; per-app deps genuinely differ (tui has no HTTP client, ai has no terminal); leaves the door open to publish `octo_pi_ai` / `octo_pi_agent` as standalone Hex libs. Compiler enforces dep graph, not a linter. No `apps/shared` — shared code lives in the app that owns it most.
2. ~~**Req vs. Finch directly?**~~ **Resolved 2026-04-23 (ticket `octo-42f.1`): Req.** The upstream provider (`pi-mono/packages/ai/src/providers/anthropic.ts`) does not delegate SSE parsing to its HTTP client — it hand-rolls the byte → line → event pipeline on top of a raw `ReadableStream<Uint8Array>` from fetch. Our HTTP client plays the same role: a byte-chunk pipe. Req's `into: :self` gives us exactly that. No Finch-specific capability is needed for Phase 1; we can drop to Finch later if pool semantics ever matter. See `docs/port-map/anthropic.md` §2.
3. ~~**Cancellation semantics for in-flight HTTP**~~ **Resolved 2026-04-23 (ticket `octo-42f.1`): kill the producer GenServer.** The Anthropic stream is owned by an unnamed `Producer` GenServer that holds the Req request; Req is process-linked, so the request terminates when the producer exits. Two lanes: `Stream.resource/3`'s `after` fun on caller-side halt, or an external `Process.exit/2`. Both release the socket cleanly — no dangling SSE state, no leaked sockets. This is materially simpler than upstream's two-path `AbortSignal` threading (signal-into-fetch + pre-read `signal?.aborted` poll). See `docs/port-map/anthropic.md` §7.2.
4. **How faithful to upstream JSONL?** Strict byte-compatibility means we can't extend entries without bumping version. Worth it if we want session-format portability. Leaning yes.
5. **Raw-mode strategy for TUI**: spawn `stty` (easiest, works today) vs. write a `termios` NIF (correct, more work). Start with `stty` and revisit if it bites.
6. **Licensing + attribution**: pi-mono is MIT. We must preserve the MIT notice and attribute the upstream work in `LICENSE` and likely a `CREDITS.md`.
7. **Where does the actual OTP-vs-pi-TS delta *add value* for users?** Candidates: multi-session daemon mode (run N agents concurrently behind one `pi` process), hot-reload tools without restart, proper supervision of bash children, cluster-aware session discovery. Worth picking one as a differentiator for the octo_pi project identity.

---

## 8. Deep dives

These three sections exist because §3 only got to "Session = GenServer, loop = Task" — but the **subtleties** (when exactly does steering fire? what does the diff algorithm actually do on shrink? what does a `tool_call` handler returning `{block: true}` actually look like chained with three other extensions?) are where the real porting bugs will live. Read these before writing code for `OctoPi.Agent`, `OctoPi.TUI`, or `OctoPi.Coder.Extension`.

### 8.1 `pi-agent-core` control flow — the parts that will trip the port

**Steer vs. follow-up: when each drains.**

| Operation | Where it enqueues | Where it drains | Source |
|-----------|-------------------|-----------------|--------|
| `steer(msg)` | `steeringQueue` (agent.ts:252) | **After** the assistant turn's tool executions complete, **before** the next LLM call. Loop calls `getSteeringMessages()` at `agent-loop.ts:218`; drained messages get injected into context at `agent-loop.ts:180-186`. | Inner-loop boundary |
| `followUp(msg)` | `followUpQueue` (agent.ts:257) | **Only when the agent would otherwise stop** — no more tool calls, no pending steer. `agent-loop.ts:222-226` drains after the inner loop exits; if non-empty, outer loop re-enters. | Outer-loop boundary |

Both queues ship with a **`mode: "all" | "one-at-a-time"`** flag (agent.ts:55, defaulting to `one-at-a-time` per agent.ts:200–201). `PendingMessageQueue.drain()` (agent.ts:126–139) either slices the whole queue or shifts one element. Drainage is strictly turn-boundary — calling `steer()` during tool execution **does not interrupt**; the message is simply queued and picked up after `turn_end`.

`followUp()` fired after `agent_end` does **not restart the loop** on its own — it just enqueues. The message is picked up by the *next* `prompt()` or `continue()` call. This is an important subtlety: in OTP, a subscriber calling `Session.follow_up/2` on an idle session won't cause the session to wake up unless we *also* trigger a continuation. We should either:

- match the TS semantic exactly (follow_up is inert until prompted), or
- improve it by waking the loop if idle (would need to be explicit so behavior doesn't surprise upstream-compatible users).

Lean matching TS for now; can relax later.

Queues are **unbounded** in TS. In Elixir we should bound them (e.g., 1000 messages) and return an error on overflow — unbounded queues are a memory-leak footgun.

**Cancellation, precisely.**

`agent.abort()` → `abortController.abort()`. The `AbortSignal` is threaded through:

1. The LLM stream (agent-loop.ts:269–273) — the stream function **must** poll `signal.aborted` and emit an `error` event with `stopReason: "aborted"`. The contract (types.ts:18–22) explicitly forbids throwing; errors are stream events.
2. Running tool executions (agent-loop.ts:577–580) — tools receive the signal and must honor it. A tool that ignores the signal hangs the loop forever. **There is no loop-level timeout.**
3. Pending-but-not-started tools — once a tool is in the `Promise.all()` batch (agent-loop.ts:457–459), it will run to completion. Abort can't yank it out mid-batch.
4. Outer loop — on `stopReason === "error" | "aborted"` the loop emits `turn_end` + `agent_end` and returns (agent-loop.ts:194–197).

Post-abort state: `isStreaming = false`, `streamingMessage = nil`, any partial message stays in `messages`, and a synthetic assistant message with `stopReason: "aborted"` is appended by `handleRunFailure()` (agent.ts:463–478). `continue()` then *fails* because the last message is an assistant message (agent.ts:336), but `prompt()` works fine.

**OTP translation:**

- Loop runs as a linked `Task` under the Session GenServer. `abort` = `Task.shutdown(task, :brutal_kill)`. Exit propagates to linked tool tasks (parallel execution is `Task.async_stream/3` — tasks are linked to the caller).
- In-flight `Req`/`Finch` HTTP requests need explicit cancellation; store the request ref in the Session state so `terminate/2` of the loop task can cancel them.
- Per-task "prepared but not started" is automatically handled: `Task.async_stream/3` with `on_timeout: :kill_task` and cancelling the whole stream kills pending tasks too.
- **No timeouts anywhere in upstream** — we should not add one silently. If we want timeouts, expose them as explicit `Session.prompt(pid, msg, timeout: …)` options that raise / cancel on expiry.
- Tool errors (thrown exceptions): caught in `executePreparedToolCall()` at agent-loop.ts:597–602, wrapped in an error `ToolResultMessage`, loop continues. In Elixir, wrap the tool callback in `try/rescue` inside the task; convert exceptions to an error result. Loop crashes are a separate concern — those are caught by the `runWithLifecycle` outer `try` (agent.ts:454–460) and produce the synthetic error message.

**Listener barrier semantics — the most surprising bit.**

`processEvents()` at agent.ts:495–542:

```ts
for (const listener of this.listeners) {
  await listener(event, signal);  // line 540
}
```

**Every listener is awaited in subscription order. The loop does not advance until all listeners for the current event have settled.** A slow listener stalls the entire agent. A throwing listener crashes the loop (caught by the outer try, which emits a synthetic error). There is **no timeout, no parallelism, no cancellation-from-listener**. Listeners are strictly observers; they receive the `AbortSignal` as a parameter but cannot signal cancellation back.

Mutation / cancellation happens via the separate **`beforeToolCall` / `afterToolCall` hooks** (`config.beforeToolCall`, not listeners — agent-loop.ts:536–552, 617–641), which are part of the loop **config object** passed in at loop construction, not the event subscription system. Extensions in the coding-agent layer wire these hooks into their own plugin system (see §8.3).

**OTP translation:**

- **Subscribers as PIDs**, not function refs. The loop `GenServer.call`s each subscriber in order (synchronous barrier) for events the loop cares about synchronously.
- For fire-and-forget UI events, use `GenServer.cast` or `Phoenix.PubSub` broadcast — these don't barrier.
- Distinguish the two in the API: `subscribe/3` takes a `mode: :sync | :async` flag.
- A subscriber that needs to time out is the subscriber's own problem (GenServer timeout on its own handler), not the loop's.
- Do not build a listener-as-transformer API. Keep listeners observer-only. If extensions want to transform, they use the config hooks (`:before_tool_call`, `:after_tool_call`) which are first-class in the Session struct.

---

### 8.2 `pi-tui` renderer internals — so we can write the Elixir equivalent cold

**Render coalescing.** `MIN_RENDER_INTERVAL_MS = 16` (tui.ts:230). `requestRender()` sets `renderRequested = true` and schedules `scheduleRender` on `nextTick`. Subsequent calls in the same microtask no-op at tui.ts:496. At tick: measure elapsed, `setTimeout(doRender, max(0, 16 - elapsed))`. If `renderRequested` is still true after `doRender`, recurse. Net effect: at most ~62fps, N calls per frame collapse to one.

In Elixir: `Process.send_after(self(), :do_render, max(0, 16 - elapsed))` with a boolean `render_requested` in state. Drop duplicate requests. After rendering, check flag, maybe reschedule.

**Line diff — the exact algorithm.** `tui.ts:984–1006`:

```ts
let firstChanged = -1, lastChanged = -1;
const maxLines = Math.max(newLines.length, this.previousLines.length);
for (let i = 0; i < maxLines; i++) {
  const oldLine = i < this.previousLines.length ? this.previousLines[i] : "";
  const newLine = i < newLines.length ? newLines[i] : "";
  if (oldLine !== newLine) {
    if (firstChanged === -1) firstChanged = i;
    lastChanged = i;
  }
}
if (newLines.length > previousLines.length) {
  if (firstChanged === -1) firstChanged = previousLines.length;
  lastChanged = newLines.length - 1;
}
```

O(max(n, m)) single pass. Shrink case: deleted trailing lines compare against `""`, register as changes, `firstChanged`/`lastChanged` straddle the deleted region — diff logic still works.

Elixir sketch (don't use `Enum.at/2` in a reduce — it's O(n) per call):

```elixir
defp diff_lines(prev, new) do
  prev_arr = :array.from_list(prev)
  new_arr  = :array.from_list(new)
  max_len  = max(length(prev), length(new))

  {first, last} =
    Enum.reduce(0..(max_len - 1)//1, {-1, -1}, fn i, {f, l} ->
      old_line = safe_get(prev_arr, i, "")
      new_line = safe_get(new_arr, i, "")
      cond do
        old_line == new_line -> {f, l}
        f == -1              -> {i, i}
        true                 -> {f, i}
      end
    end)

  case {length(new) > length(prev), first} do
    {true, -1} -> {length(prev), length(new) - 1}
    {true, _}  -> {first, length(new) - 1}
    _          -> {first, last}
  end
end
```

(Alternative: use `:counters` or a tuple rather than `:array` — benchmark before committing.)

**Full-redraw branches** (tui.ts:952–982) — four cases that bypass the diff entirely:

1. First render (`previousLines.length == 0 && !widthChanged && !heightChanged`) — emit all lines, no clear.
2. Width changed — clear screen + scrollback, full render.
3. Height changed (unless Termux) — clear screen + scrollback, full render.
4. `clearOnShrink && newLines.length < maxLinesRendered && overlayStack.length == 0` — full render with clear.

Everything else goes through the differential path.

**Patch buffer is one string, one write** (tui.ts:1187). CSI 2026 opens it (`\x1b[?2026h`), cursor moves to `firstChanged`, each changed line is `\x1b[2K` + content, trailing deleted lines get `\r\n\x1b[2K`, then `\x1b[?2026l` closes it. Then one `terminal.write(buffer)`.

In Elixir: build an `iodata` list and `IO.binwrite(port, iodata)` once. BEAM's `iodata` is a first-class concept — no need to flatten.

**Overlays composite before diff.** `tui.ts:908` sets `newLines = compositeOverlays(newLines, width, height)` *before* the diff scan runs. So overlays become part of the `newLines` snapshot that both renders and gets stored as `previousLines`. No special handling on dismiss — next frame just omits the overlay from composite, and the normal diff figures out what to clear.

Composition (tui.ts:734–794): sort overlays by `focusOrder` ascending (older underneath), pre-render each at its resolved width, clip to `maxHeight`, position by anchor + offsets + margins, then for each overlay iterate its lines and splice them into the base buffer at `(row, col)` using `compositeLineAt` (which handles wide-char-aware ANSI-preserving column overwrites — we'll need an Elixir `slice_by_column/3` equivalent for this).

**Stdin sequence boundary detection.** `stdin-buffer.ts`'s `isCompleteSequence` recognizes: CSI (`ESC [ … final-byte-in-0x40..0x7E`), OSC (`ESC ] … ST-or-BEL`), DCS (`ESC P … ST`), APC (`ESC _ … ST`), SS3 (`ESC O + 1 byte`), mouse (`ESC [ M + 3 bytes`), meta (`ESC + 1 byte`), plus special-case SGR mouse validation. Incomplete sequences: wait up to `timeoutMs = 10ms`, then flush as-is.

Bracketed paste: `\x1b[200~` enters paste mode — all subsequent bytes go into `pasteBuffer` without sequence parsing. `\x1b[201~` exits. Paste content can contain literal escape sequences; they're data, not delimiters. If a paste start marker arrives mid-chunk, content before is parsed normally, then paste mode engages.

Kitty protocol query: send `\x1b[?u`, wait for response `\x1b[?<flags>u`. The response arrives on stdin and is **intercepted** by a pattern match in the terminal wrapper (terminal.ts:133–144) — **not** forwarded to the input handler. If the response is split across chunks, the stdin buffer reassembles before match. No race.

**Elixir shape:**

```elixir
defmodule OctoPi.TUI.StdinBuffer do
  # GenServer: state = {mode, buffer, paste_buffer, timer_ref}
  # mode = :normal | :paste | :kitty_query_pending

  def handle_info({:stdin, bytes}, state) do
    state = %{state | buffer: state.buffer <> bytes}
    state = maybe_cancel_timer(state)
    state = drain(state)
    {:noreply, state}
  end

  defp drain(%{mode: :paste} = state), do: paste_drain(state)
  defp drain(state) do
    case extract_one_sequence(state.buffer) do
      {:complete, seq, rest}        -> emit(seq); drain(%{state | buffer: rest})
      {:paste_start, rest}          -> drain(%{state | mode: :paste, buffer: rest})
      {:incomplete, _}              -> arm_timeout(state, 10)
      :empty                        -> state
    end
  end

  # binary pattern matching for each sequence class — one clause per class
  defp extract_one_sequence(<<0x1b, ?[, rest::binary>>), do: parse_csi(rest)
  defp extract_one_sequence(<<0x1b, ?], rest::binary>>), do: parse_osc(rest)
  # ... etc
end
```

BEAM's binary pattern matching makes this dramatically cleaner than TS. Estimated ~200 LOC vs. ~700 TS.

---

### 8.3 `pi-coding-agent` extensions system — the 20+ event plugin architecture

The earlier survey called this "hooks." It's not. It's a full plugin dispatcher with **27 event types**, **seven distinct emission patterns**, and cancelable/mutable/chainable payloads. Getting this wrong will make the Elixir extension API cramped. Getting it right unlocks everything that makes `pi` actually useful (inline-bash, dirty-repo-guard, per-project skills, etc.).

**Extensions are factory functions, not classes.** (types.ts:1354):

```ts
type ExtensionFactory = (pi: ExtensionAPI) => void | Promise<void>;
```

Each extension is a file exporting a default function. At load, the function is called and registers handlers via `pi.on(eventName, handler)`. State lives in closures — the `pirate` extension keeps `let pirateMode = false` at module scope; the `todo` extension reconstructs from session entries on `session_start`/`session_tree`. No per-extension state machine, no lifecycle hooks. This is deliberately lightweight.

**The seven emission patterns.** The runner (runner.ts:673–1018) has different dispatch semantics depending on the event. This matters enormously for the OTP port because you can't paper over it with a single `emit/2` — each pattern encodes a different contract:

| Pattern | Events | Semantics |
|---------|--------|-----------|
| **Fire-and-forget** | `agent_start`, `agent_end`, `turn_start`, `turn_end`, `message_*`, `tool_execution_*`, `model_select`, `session_start`, `session_compact`, `session_shutdown`, `after_provider_response` | Call all handlers in order. Ignore returns. Errors swallowed + logged. |
| **Cancel-on-result** | `session_before_switch`, `session_before_fork`, `session_before_compact`, `session_before_tree` | Sequential. First handler returning `{cancel: true, ...}` short-circuits and returns the cancel result. |
| **Reduce/chain** | `context`, `before_provider_request`, `input` | Each handler's return replaces the payload passed to the next. Last non-nil value wins. |
| **Mutate in place** | `tool_call` | Handler mutates `event.input` directly. First handler returning `{block: true, reason}` cancels the tool. |
| **Patch-merge** | `tool_result` | Each handler returns `{content?, details?, isError?}`; fields merge into current event. Chained. |
| **First-result-wins** | `user_bash` | First handler returning a non-nil result wins; remaining handlers skipped. |
| **Parallel-collect** | `resources_discover` | All handlers called; returned paths concatenated. |

**Concrete examples** (from upstream):

`input` chain with short-circuit (`examples/extensions/input-transform.ts`):

```ts
pi.on("input", async (event, ctx) => {
  if (event.text.startsWith("?quick ")) {
    return { action: "transform", text: `Respond briefly: ${event.text.slice(7)}` };
  }
  if (event.text.toLowerCase() === "ping") {
    ctx.ui.notify("pong");
    return { action: "handled" };   // short-circuits — bypasses agent entirely
  }
  return { action: "continue" };
});
```

`tool_call` block (conceptual — many extensions do this):

```ts
pi.on("tool_call", async (event) => {
  if (event.toolName === "bash" && looksDangerous(event.input.command)) {
    return { block: true, reason: "dangerous command" };
  }
  // otherwise mutate event.input in place to sanitize
  event.input.command = sanitize(event.input.command);
});
```

**OTP translation — the concrete API.**

Because the seven patterns have different semantics, the cleanest Elixir API gives each its own dispatcher entry point, unified under one behaviour:

```elixir
defmodule OctoPi.Coder.Extension do
  @callback init(context :: map()) :: {:ok, state :: any()}

  # Fire-and-forget events — return value ignored
  @callback on_event(event :: atom(), payload :: map(), state) :: :ok

  # Cancelable events
  @callback on_gate(event :: atom(), payload, state) ::
              :pass | {:cancel, reason :: String.t()}

  # Reduce/chain events
  @callback on_transform(event :: atom(), payload, state) ::
              {:ok, new_payload :: map()} | :unchanged

  # Tool-call gate+mutate
  @callback on_tool_call(payload, state) ::
              {:allow, new_input :: map()} | {:block, reason :: String.t()}

  # Tool-result patch-merge
  @callback on_tool_result(payload, state) ::
              {:patch, %{optional(:content) => any(),
                         optional(:details) => any(),
                         optional(:is_error) => boolean()}}
              | :unchanged

  # user_bash first-result-wins
  @callback on_user_bash(payload, state) ::
              {:handled, result :: map()} | :pass

  @optional_callbacks [on_event: 3, on_gate: 3, on_transform: 3,
                       on_tool_call: 2, on_tool_result: 2, on_user_bash: 2]
end
```

The dispatcher is a **GenServer** holding `extensions: [{module, state}]` in registration order. Each emission pattern is a separate function:

```elixir
defmodule OctoPi.Coder.Events do
  def broadcast(event, payload),       do: GenServer.cast(...)   # fire-and-forget
  def gate(event, payload),            do: GenServer.call(...)   # cancel-on-result; :pass | {:cancel, reason}
  def transform(event, payload),       do: GenServer.call(...)   # reduce-chain
  def tool_call(payload),              do: GenServer.call(...)   # allow+mutate | block
  def tool_result(payload),            do: GenServer.call(...)   # patch-merge
  def user_bash(payload),              do: GenServer.call(...)   # first-result-wins
  def resources_discover(payload),     do: GenServer.call(...)   # parallel-collect
end
```

**Why a GenServer and not `Phoenix.PubSub` or `Registry`:**

- PubSub is fire-and-forget only. The *fire-and-forget* events could run through PubSub, but the other six patterns need **sequential iteration with return-value chaining**, which PubSub can't give us.
- `Registry` is name-based lookup. We need ordered iteration.
- GenServer serializes through one process — fine, because event dispatch is already on the critical path of a single session and extensions are not a hot path.

**State discipline:** store extension state in the dispatcher keyed by `{module, session_id}`. On session switch/reload, re-run `init/1`. Don't force extensions to become GenServers themselves — upstream treats them as stateless callbacks with closure state, and that's a simpler and better API.

**Errors:** wrap each handler invocation in `try/rescue`. Log + continue (matches TS runner.ts:691–699). A crashing extension does not crash the session.

**Signal:** the TS version passes an `AbortSignal` to handlers for long-running work (compaction, tree summarization). In Elixir, pass a `cancel_ref :: reference()` in the context map; extensions check `OctoPi.Coder.Events.cancelled?(cancel_ref)` or the dispatcher can `Process.exit(handler_task, :cancelled)` if it's running in a supervised subtask.

---

## Appendix: where to read the code

Shallow clone at `tmp/pi-mono/` (git-ignored). Key files cited above:

- **pi-ai**: `packages/ai/src/{types.ts,stream.ts,api-registry.ts,event-stream.ts,providers/anthropic.ts,env-api-keys.ts}`
- **pi-agent-core**: `packages/agent/src/{agent.ts,agent-loop.ts,proxy.ts,types.ts}`
- **pi-coding-agent**: `packages/coding-agent/src/{cli.ts,main.ts,core/tools/{index,read,bash,edit,write}.ts,core/session-manager.ts,core/extensions/{runner,types}.ts,modes/{interactive,print-mode,rpc}.ts,migrations.ts}`
- **pi-tui**: `packages/tui/src/{tui.ts,terminal.ts,keys.ts,stdin-buffer.ts,components/editor.ts,kill-ring.ts,undo-stack.ts}`
- **pi-mom**: `packages/mom/src/{main.ts,slack.ts,agent.ts}`
- **pi-pods**: `packages/pods/src/{cli.ts,commands/{pods,models}.ts,ssh.ts}`
- **pi-web-ui**: `packages/web-ui/src/{ChatPanel.ts,components/{AgentInterface,Messages,MessageList}.ts,tools/artifacts/artifacts.ts}`

Upstream repo: <https://github.com/badlogic/pi-mono> (v0.69.0 at time of research).
