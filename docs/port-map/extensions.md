# Port map: extensions system (pi-coding-agent → octo_pi_coder)

Porting spec for Phase 6 — the extension/plugin architecture that lets
external code hook into 26 lifecycle events via six distinct emission
patterns. Built on top of the Phase 3 coder (`OctoPi.Coder`).
Canonical reference: pi-mono at
`tmp/pi-mono/packages/coding-agent/src/core/extensions/`.

**Primary sources (read first):**
- `tmp/pi-mono/packages/coding-agent/src/core/extensions/types.ts` — all types, event definitions, ExtensionAPI (1543 lines)
- `tmp/pi-mono/packages/coding-agent/src/core/extensions/runner.ts` — dispatcher, context, lifecycle (1000+ lines)
- `tmp/pi-mono/packages/coding-agent/src/core/extensions/loader.ts` — discovery, loading, API creation (606 lines)
- `tmp/pi-mono/packages/coding-agent/src/core/event-bus.ts` — inter-extension pub/sub (34 lines)
- `tmp/pi-mono/packages/coding-agent/src/core/extensions/wrapper.ts` — tool wrapping (31 lines)

**Test sources:**
- `tmp/pi-mono/packages/coding-agent/test/extensions-discovery.test.ts`
- `tmp/pi-mono/packages/coding-agent/test/extensions-runner.test.ts`
- `tmp/pi-mono/packages/coding-agent/test/extensions-input-event.test.ts`
- `tmp/pi-mono/packages/coding-agent/test/agent-session-runtime-events.test.ts`
- `tmp/pi-mono/packages/coding-agent/test/compaction-extensions.test.ts`

---

## 1. Architecture overview

The upstream extensions system has three layers:

1. **Types & registration** — `Extension` struct, event type atoms, handler
   function signatures, `ExtensionAPI` (the object passed to extensions
   during init so they can register handlers, tools, and commands).

2. **Dispatcher** (`ExtensionRunner`) — owns the ordered list of loaded
   extensions. Provides one dispatch function per emission pattern. Each
   dispatch iterates extensions → handlers, wrapping each call in
   try/catch. Errors emit to error listeners (we use telemetry).

3. **Loader** — discovers extension files on disk, creates `ExtensionAPI`
   wrappers, calls each extension's factory function, collects
   registrations into `Extension` structs.

### 1.1 OTP mapping

| Upstream | Elixir |
|----------|--------|
| `Extension` object | `%OctoPi.Coder.Extension{}` struct |
| `ExtensionRunner` class | `OctoPi.Coder.Extension.Dispatcher` (GenServer or plain module) |
| `loader.ts` discover/load | `OctoPi.Coder.Extension.Loader` module |
| `ExtensionAPI` object | `%OctoPi.Coder.Extension.API{}` struct with fn fields |
| `EventBus` | `OctoPi.Coder.Extension.EventBus` (Registry-based) |
| Error listeners | `:telemetry` events |
| `ExtensionFactory` | `@callback init(api) :: :ok` behaviour |

---

## 2. Extension struct

Upstream `Extension` (types.ts lines 1513-1543):

```typescript
interface Extension {
  path: string;
  resolvedPath: string;
  sourceInfo: SourceInfo;
  handlers: Map<string, HandlerFn[]>;
  tools: Map<string, RegisteredTool>;
  messageRenderers: Map<string, MessageRenderer>;
  commands: Map<string, RegisteredCommand>;
  flags: Map<string, ExtensionFlag>;
  shortcuts: Map<KeyId, ExtensionShortcut>;
}
```

**OTP mapping:**

```elixir
defmodule OctoPi.Coder.Extension do
  @type handler_fn :: (event :: map(), context :: Context.t() -> term())

  @type t :: %__MODULE__{
    id: String.t(),
    path: String.t(),
    handlers: %{event_type() => [handler_fn()]},
    tools: %{String.t() => OctoPi.Agent.Tool.t()},
    commands: %{String.t() => command_spec()}
  }

  defstruct [:id, :path, handlers: %{}, tools: %{}, commands: %{}]
end
```

We drop `messageRenderers`, `flags`, and `shortcuts` — those are
TUI-specific concerns that can be added later.

---

## 3. Event types (26 total)

Complete catalog from types.ts lines 938-959. Grouped by emission pattern.

### 3.1 Fire-and-forget events

No return value needed. All handlers called, results ignored.

| Event | When fired | Payload fields |
|-------|-----------|----------------|
| `session_start` | Session started/loaded/reloaded | `session_id`, `reason` (`:new` / `:resume` / `:reload`) |
| `session_shutdown` | Before extension shutdown | (none) |
| `session_compact` | After compaction completes | `compacted_length`, `custom_instructions` |
| `session_tree` | After tree navigation | `direction` |
| `agent_start` | Agent loop started | `session_id` |
| `agent_end` | Agent loop ended | `session_id`, `reason` |
| `turn_start` | Turn started | `turn_number` |
| `turn_end` | Turn ended | `turn_number`, `stop_reason` |
| `message_start` | Message started | `role` (`:user` / `:assistant` / `:tool_result`) |
| `message_update` | Assistant streaming token | `partial` (accumulated text) |
| `message_end` | Message ended | `message`, `role` |
| `tool_execution_start` | Tool execution started | `tool_name`, `tool_use_id`, `input` |
| `tool_execution_update` | Tool execution streaming | `tool_name`, `tool_use_id`, `content` |
| `tool_execution_end` | Tool execution ended | `tool_name`, `tool_use_id`, `result` |
| `model_select` | Model selected/changed | `model` |
| `after_provider_response` | After provider response received | `response` |

### 3.2 Cancel-on-result events

First handler returning `{:cancel, reason}` short-circuits. All others
return `:ok` or `nil`.

| Event | When fired | Cancel semantics |
|-------|-----------|-----------------|
| `session_before_switch` | Before switching sessions | Blocks the switch |
| `session_before_fork` | Before forking a session | Blocks the fork |
| `session_before_compact` | Before compaction | Blocks compaction |
| `session_before_tree` | Before tree navigation | Blocks navigation |

### 3.3 Reduce-chain events

Handlers transform a value sequentially. Each receives the output of the
previous handler.

| Event | Accumulator | Handler return |
|-------|------------|----------------|
| `context` | `[AgentMessage.t()]` | `%{messages: [...]}` or `nil` (no change) |
| `before_provider_request` | raw payload (map) | transformed payload or `nil` |
| `input` | `{text, images, source}` | `{:transform, text, images}` / `:handled` / `:continue` |

**`input` is special:** `:handled` causes early exit (the input is
considered fully processed by the extension). `:transform` chains.
`:continue` passes through unchanged.

### 3.4 Mutate-in-place event

| Event | Semantics |
|-------|----------|
| `tool_call` | `event.input` is a mutable map. Handlers modify it in-place to patch tool arguments. Later handlers see earlier mutations. Return `{:block, reason}` to prevent execution. |

Upstream doc (types.ts lines 804-808): "Mutate `event.input` in place to
patch tool arguments before execution. Later `tool_call` handlers see
earlier mutations. No re-validation is performed after mutation."

**OTP mapping:** Since Elixir data is immutable, the dispatcher threads
the event through handlers, replacing `event.input` with each handler's
returned input. This achieves the same sequential-mutation semantics.

### 3.5 Patch-merge event

| Event | Semantics |
|-------|----------|
| `tool_result` | Handlers return partial maps with optional keys `:content`, `:details`, `:is_error`. All patches are merged in order (later wins per-key). |

Upstream (runner.ts lines 707-755): patches `content`, `details`,
`isError` fields individually. Only returns a result if at least one
handler modified something.

### 3.6 First-result / collect-all events

| Event | Pattern |
|-------|---------|
| `user_bash` | First non-nil result wins. Can replace bash execution entirely. |
| `before_agent_start` | Hybrid: accumulates all injected messages into a list, chains system_prompt (last writer wins). |
| `resources_discover` | Collect-all: gathers skill/prompt/theme paths from all handlers, deduplicates by resolved path. |

---

## 4. Dispatcher (ExtensionRunner)

Upstream class: `ExtensionRunner` in runner.ts, ~800 lines of dispatch
logic. Each pattern has its own dispatch method.

### 4.1 Dispatch methods

```
emit(event)                    → fire-and-forget / cancel-on-result
emitToolCall(event)            → mutate-in-place
emitToolResult(event)          → patch-merge
emitUserBash(event)            → first-result-wins
emitContext(messages)          → reduce-chain
emitBeforeProviderRequest(p)   → reduce-chain
emitInput(text, images, src)   → reduce-chain + early-exit
emitBeforeAgentStart(...)      → accumulate + chain
emitResourcesDiscover(cwd, r)  → collect-all
```

### 4.2 OTP mapping

```elixir
defmodule OctoPi.Coder.Extension.Dispatcher do
  @doc "Fire-and-forget: call all handlers, ignore results."
  @spec fire_and_forget([Extension.t()], event()) :: :ok

  @doc "Cancel-on-result: short-circuit on {:cancel, reason}."
  @spec cancel_on_result([Extension.t()], event()) :: :ok | {:cancel, term()}

  @doc "Reduce-chain: fold handlers over accumulator."
  @spec reduce_chain([Extension.t()], event_type(), acc) :: acc

  @doc "Mutate-in-place: thread event.input through handlers."
  @spec mutate_in_place([Extension.t()], tool_call_event()) ::
    {:ok, tool_call_event()} | {:block, term()}

  @doc "Patch-merge: collect partial patches, merge in order."
  @spec patch_merge([Extension.t()], tool_result_event()) ::
    {:ok, map()} | :unchanged

  @doc "First-result: return first non-nil handler result."
  @spec first_result([Extension.t()], event()) :: term() | nil
end
```

Each dispatch function iterates `extensions` → `handlers`, wrapping each
call in `try/rescue`. On error:

```elixir
try do
  handler.(event, context)
rescue
  e ->
    :telemetry.execute(
      [:octo_pi_coder, :extension, :handler_error],
      %{},
      %{extension_id: ext.id, event_type: event.type,
        error: Exception.message(e), stacktrace: __STACKTRACE__}
    )
    Logger.warning("Extension #{ext.id} handler error on #{event.type}: #{Exception.message(e)}")
    nil
end
```

### 4.3 Context

Fresh context created per dispatch call (runner.ts line 674):

```elixir
defmodule OctoPi.Coder.Extension.Context do
  @type t :: %__MODULE__{
    model: OctoPi.AI.Model.t() | nil,
    cwd: String.t(),
    session_id: String.t() | nil,
    idle?: boolean(),
    signal: reference() | nil
  }
end
```

### 4.4 Ordering guarantees

- Extensions execute in **registration order** (discovery order: local → global → configured).
- Handlers within an extension execute in **registration order** (order of `api.on()` calls).
- No parallelism within a dispatch — all sequential for determinism.

---

## 5. Extension loading

Upstream: `loader.ts` (606 lines).

### 5.1 Discovery

Three sources, in order:

1. **Project-local:** `cwd/.octo_pi/extensions/` (upstream uses `.pi/extensions/`)
2. **Global:** `~/.octo_pi/extensions/`
3. **Configured:** paths from settings file

Within each directory:
- Direct `.ex` files → load as extension modules
- Subdirectories with `index.ex` → load index
- Subdirectories with `mix.exs` → treat as dependency (future)

### 5.2 Loading process

```
for path in discovered_paths do
  1. Create empty %Extension{id: basename(path), path: path}
  2. Create %ExtensionAPI{} with registration fns that mutate the Extension
  3. Call Module.init(api) — extension registers handlers via api.on()
  4. Collect completed Extension into ordered list
end
```

**Error handling:** If a single extension fails to load, log a warning
and skip it. Never crash the system.

### 5.3 ExtensionAPI

The API object passed to each extension's `init/1`:

```elixir
defmodule OctoPi.Coder.Extension.API do
  @type t :: %__MODULE__{
    on: (event_type(), handler_fn() -> :ok),
    register_tool: (Tool.t() -> :ok),
    register_command: (command_spec() -> :ok),
    events: EventBus.t(),
    # Action callbacks — bound after all extensions load:
    send_message: (String.t() -> :ok),
    get_model: (-> Model.t() | nil),
    set_model: (Model.t() -> :ok),
    get_thinking_level: (-> String.t() | nil),
    set_thinking_level: (String.t() -> :ok),
    abort: (-> :ok),
    compact: (keyword() -> :ok),
    get_system_prompt: (-> String.t()),
    get_active_tools: (-> [Tool.t()]),
    set_active_tools: ([String.t()] -> :ok),
  }
end
```

Upstream has a two-phase binding: during load, action callbacks are stubs
that raise. After `bind_core()`, they're replaced with real impls that
talk to the session. In OTP, we can use `{:via, ...}` or pass pid refs.

### 5.4 bind_core phase

Upstream runner.ts lines 261-331. After all extensions are loaded and the
session is ready, `bindCore()` wires the action callbacks to real session
functions:

- `sendMessage` → `OctoPi.Agent.prompt/2`
- `getModel` → `OctoPi.Agent.Session` state
- `setModel` → session state update
- `abort` → session abort signal
- `compact` → `OctoPi.Agent.Session.compact/2`
- `getSystemPrompt` → session config
- `getActiveTools` / `setActiveTools` → tool registry

---

## 6. EventBus (inter-extension pub/sub)

Upstream: `event-bus.ts` (34 lines). Simple pub/sub for extensions to
communicate with each other without going through the dispatch system.

### 6.1 API

```elixir
defmodule OctoPi.Coder.Extension.EventBus do
  @spec emit(server(), String.t(), term()) :: :ok
  @spec on(server(), String.t(), (term() -> :ok)) :: (() -> :ok)  # returns unsubscribe fn
  @spec clear(server()) :: :ok
end
```

### 6.2 OTP mapping

Use `Registry` with `{:via, Registry, {EventBus, channel}}` dispatch, or
a simple GenServer holding `%{channel => [handler_fn]}`. Handlers execute
asynchronously (fire-and-forget). Errors logged, don't propagate.

---

## 7. Telemetry events

All extension lifecycle events emit telemetry for observability:

| Event name | Measurements | Metadata |
|-----------|-------------|----------|
| `[:octo_pi_coder, :extension, :loaded]` | `%{count: 1}` | `%{id, path, handler_count, tool_count}` |
| `[:octo_pi_coder, :extension, :load_error]` | `%{}` | `%{path, error}` |
| `[:octo_pi_coder, :extension, :emit]` | `%{duration: native}` | `%{event_type, pattern, handler_count}` |
| `[:octo_pi_coder, :extension, :handler_error]` | `%{}` | `%{extension_id, event_type, error, stacktrace}` |
| `[:octo_pi_coder, :extension, :handler_cancel]` | `%{}` | `%{extension_id, event_type, reason}` |

### 7.1 Log handler

`OctoPi.Coder.Extension.TelemetryHandler` attaches to all of the above:
- `:loaded` → `Logger.info("Extension #{id} loaded (#{handler_count} handlers)")`
- `:load_error` → `Logger.warning("Failed to load extension at #{path}: #{error}")`
- `:emit` → `Logger.debug("Dispatched #{event_type} (#{pattern}, #{handler_count} handlers, #{duration}µs)")`
- `:handler_error` → `Logger.warning("Extension #{id} error on #{event_type}: #{error}")`
- `:handler_cancel` → `Logger.info("Extension #{id} cancelled #{event_type}: #{reason}")`

Enable with `mix pi --debug-extensions` or `config :octo_pi_coder, :debug_extensions, true`.

---

## 8. Error handling

### 8.1 Handler errors

Upstream (runner.ts lines 691-700): each handler wrapped in try/catch.
On error, emits `ExtensionError`:

```typescript
{
  extensionPath: ext.path,
  event: event.type,
  error: message,
  stack: stack
}
```

Error listeners are notified. Handler continues to next.

**OTP mapping:** `try/rescue` + `:telemetry.execute`. The error is logged
and the handler is skipped. The dispatch continues with the next handler.

### 8.2 Load errors

Extension load failures are logged and skipped. The system starts with
whatever extensions loaded successfully.

### 8.3 Extension isolation

A crashing extension handler must never crash the dispatcher or the
agent session. This is the primary safety invariant.

---

## 9. Upstream test patterns to port

### 9.1 Discovery tests (extensions-discovery.test.ts)

- Discovers `.ts` / `.js` files in extensions directory
- Discovers subdirectories with `index.ts`
- Discovers subdirectories with `package.json` manifest
- Prefers `.ts` over `.js` in same directory
- Handles empty directories gracefully
- Reports load errors without crashing

### 9.2 Runner tests (extensions-runner.test.ts)

- Shortcut conflict detection with built-ins
- Tool name conflict detection across extensions
- Provider registration and unregistration
- Error isolation: one handler error doesn't stop others

### 9.3 Input event tests (extensions-input-event.test.ts)

- Transform chain: handler A transforms, handler B sees transformed text
- Early exit on `:handled` — subsequent handlers not called
- `:continue` passes through unchanged
- Multiple transforms compose correctly

### 9.4 Runtime event tests (agent-session-runtime-events.test.ts)

- `tool_call` handlers can mutate input args
- `tool_call` handlers can block execution
- `tool_result` handlers can patch result content
- `context` handlers can transform message list
- Fire-and-forget events reach all handlers

### 9.5 Compaction tests (compaction-extensions.test.ts)

- `session_before_compact` can cancel compaction
- `session_compact` event fires after successful compaction

---

## 10. File structure

```
apps/octo_pi_coder/lib/octo_pi/coder/extension/
├── extension.ex          # %Extension{} struct + @type definitions
├── api.ex                # %API{} struct (passed to init)
├── context.ex            # %Context{} struct (passed to handlers)
├── dispatcher.ex         # Six dispatch functions
├── loader.ex             # Discovery + loading
├── event_bus.ex          # Inter-extension pub/sub
└── telemetry_handler.ex  # Log handler for extension telemetry

apps/octo_pi_coder/test/octo_pi/coder/extension/
├── dispatcher_test.exs   # All six patterns
├── loader_test.exs       # Discovery + loading
├── event_bus_test.exs    # Pub/sub
└── integration_test.exs  # Reference extensions end-to-end
```

---

## 11. Tickets

### 11.1 Core (P1)

| Ticket | Title | Deps |
|--------|-------|------|
| octo-3gv.1 | Extension behaviour + event types + handler storage | — |
| octo-3gv.2 | Event dispatcher: six emission patterns | .1 |
| octo-3gv.3 | Extension loading + registration + ExtensionAPI | .1 |

### 11.2 Infrastructure (P2)

| Ticket | Title | Deps |
|--------|-------|------|
| octo-3gv.4 | EventBus: inter-extension pub/sub | — |
| octo-3gv.5 | Telemetry + log handler for extension events | .2 |
| octo-3gv.6 | Reference extensions: dirty-repo-guard + input-transform | .2, .3 |
| octo-3gv.10 | Extended ExtensionAPI action methods | .3 |
| octo-3gv.11 | Command context: session control methods | .3 |
| octo-3gv.12 | Provider registration via extensions | .3 |
| octo-3gv.14 | Extension lifecycle: stale tracking + invalidation | .1 |

### 11.3 Advanced / TUI-bound (P3)

| Ticket | Title | Deps |
|--------|-------|------|
| octo-3gv.7 | Extension struct: messageRenderers, flags, shortcuts | .1 |
| octo-3gv.8 | UI Context: extension interaction with TUI | .3 |
| octo-3gv.9 | Tool rendering: renderCall, renderResult, ToolRenderContext | .1 |
| octo-3gv.13 | Runner introspection methods | .2 |
| octo-3gv.15 | Advanced loader: factory, manifest discovery, Mix deps | .3 |

**Definition of done (from epic):** a custom extension can register a
`tool_call` handler that sanitizes bash commands and a
`session_before_switch` handler that blocks on a dirty repo.
