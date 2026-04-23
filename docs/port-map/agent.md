# Port map: agent kernel (pi-agent-core → octo_pi_agent)

Porting spec for Phase 2 — the stateful agent loop, tool
orchestration, steering / follow-up queues, cancellation, and the
subscriber protocol. Canonical reference: pi-mono v0.69.0 at
`tmp/pi-mono/packages/agent/`. Line citations are into that tree.

**Primary sources (read first):**
- `tmp/pi-mono/packages/agent/src/agent-loop.ts` — inner/outer loop,
  tool dispatch, hooks
- `tmp/pi-mono/packages/agent/src/agent.ts` — the stateful Agent
  wrapper that callers use
- `tmp/pi-mono/packages/agent/src/types.ts` — contract
- `tmp/pi-mono/packages/agent/src/proxy.ts` — proxy transport (Phase 2
  ships Direct only; Proxy defers)
- `tmp/pi-mono/packages/agent/test/{agent,agent-loop}.test.ts` — tests
  to port

---

## 0. What we're building

`OctoPi.Agent.start_session(opts)` returns a `pid` to a **Session
GenServer** that owns a conversation with an LLM-backed agent:
messages, tools, streaming flag, subscribers, steering + follow-up
queues. Callers `prompt/2`, `continue/1`, `steer/2`, `follow_up/2`,
`abort/1`, `subscribe/3`, `wait_for_idle/1`. Events flow to
subscribers synchronously (`call`) or asynchronously (`send`). Tool
execution goes through a pluggable behaviour; LLM streaming goes
through a pluggable `Transport` behaviour (default `Direct` →
`OctoPi.AI.stream/3`).

Ape pi-agent-core's semantics as faithfully as possible — the hard
parts (listener barrier, cooperative abort) are called out in §10.

---

## 1. Session state

The `Agent` class holds a mutable session[^session-state]. Fields
that survive between LLM turns:

| TS field | Purpose | OTP shape |
|---|---|---|
| `messages: AgentMessage[]` | ordered transcript (user / assistant / toolResult / custom) | list in GenServer state |
| `tools: AgentTool[]` | per-session tool list; mutable at runtime | list; setter copies on assign |
| `systemPrompt: string` | prefixed to every LLM call | string |
| `model: Model` | active Anthropic/etc. model | `%OctoPi.AI.Model{}` |
| `thinkingLevel: ThinkingLevel` | reasoning level knob | atom; `:off | :minimal | :low | :medium | :high | :xhigh` |
| `isStreaming: boolean` | true while a run is in flight | boolean |
| `streamingMessage: AgentMessage?` | partial message during stream | struct or nil |
| `pendingToolCalls: Set<string>` | tool call ids executing now | `MapSet` |
| `errorMessage?: string` | last failure reason | string or nil |
| `listeners: Set<fun>` | subscribers awaited on every event | Registry |
| `steeringQueue` / `followUpQueue` | messages to inject between turns | queue module (see §5) |
| — | `:loop_task`, `:abort_ref` | new for OTP |

Sessions **aren't persisted** at this layer; that's
`pi-coding-agent` (Phase 3).

Public API[^public-api]:

```elixir
OctoPi.Agent.start_session(opts) :: {:ok, pid}
OctoPi.Agent.prompt(pid, AgentMessage.t() | [AgentMessage.t()] | String.t())
OctoPi.Agent.continue(pid)
OctoPi.Agent.steer(pid, AgentMessage.t())
OctoPi.Agent.follow_up(pid, AgentMessage.t())
OctoPi.Agent.abort(pid)
OctoPi.Agent.subscribe(pid, listener :: pid(), mode :: :sync | :async)
OctoPi.Agent.state(pid) :: state_view()
OctoPi.Agent.wait_for_idle(pid, timeout \\ 30_000)
```

---

## 2. Control flow — the loop

Two nested `while` blocks in `runLoop`[^run-loop]:

```
OUTER (agent-loop.ts L168)
  INNER (L172: while has_more_tool_calls or pending_messages)
    turn_start
    inject steering if any
    LLM stream → assistant response
    if stop_reason in [:error, :aborted]: agent_end; return
    extract tool_use blocks
    execute (parallel default, sequential if any tool.executionMode == "sequential")
    turn_end
    drain new steering (L218); loop if nonempty
  after INNER exits (no tools, no steer):
    drain follow-up (L222); re-enter INNER if any
  else break
  agent_end
```

**LLM stream** is invoked via `streamFn` (pluggable, defaults to
`pi-ai.streamSimple`)[^stream-fn]. The loop blocks on its event
stream until stop.

**Tool batching**[^tool-batching]:
- **Parallel (default)**: `prepareToolCall` serially (L430), execute
  via `Promise.all` (L457), emit tool-results in **assistant source
  order** after all finish.
- **Sequential**: prepare/execute/finalize/emit per tool (L360-410).
- **Any `executionMode: "sequential"` in the batch flips the whole
  batch to sequential** (L349).

**Loop exit**[^exit]: the assistant's `stop_reason` is `:error` or
`:aborted` (L194-197) **or** no tool calls + no steer + no follow-up
(L222-230).

---

## 3. Tools

Tool shape[^tool-shape]:

```elixir
defmodule OctoPi.Agent.Tool do
  @type t :: %__MODULE__{
    name: String.t(),
    label: String.t(),
    description: String.t(),
    parameters: map(),                    # JSON schema
    prepare_arguments: (map() -> map()) | nil,
    execution_mode: :parallel | :sequential,  # default :parallel
    execute: (tool_call_id, params, abort_ref, on_update_fn -> {:ok, result} | {:error, reason})
  }
end

defmodule OctoPi.Agent.Tool.Result do
  @type t :: %__MODULE__{
    content: [Content.Text.t() | Content.Image.t()],  # returned to model
    details: term(),                                    # structured data for logs/UI
    terminate?: boolean()                               # optional early-stop hint
  }
end
```

Handler contract[^handler-contract]: the `execute` function receives
a tool-call id, parsed params, an abort ref, and an `on_update`
callback. Must not raise for expected failures — encode as a text
error content block. Unexpected raises are caught by the loop and
wrapped into an error result (L597-602).

**No global tool registry at this layer** — tools are per-session,
stored in the Session GenServer's state[^tool-registry]. Built-in
tools (read, write, bash, etc.) come from `octo_pi_coder` in Phase 3.

---

## 4. Cancellation

`agent.abort()` (TS L288-290) sets an `AbortSignal`; the signal is
polled in the LLM stream, tool prepare/execute/finalize, and passed
to listeners[^abort-path].

OTP shape[^otp-abort]:
- Each run has an **abort ref** (just a unique reference) stored on
  the Session and threaded into the loop Task's state.
- `OctoPi.Agent.abort/1` flips an ETS flag keyed on that ref.
- Loop Task checks the flag at safe points (before LLM stream, between
  tools, inside tool callbacks that opt in) via
  `OctoPi.Agent.AbortRef.aborted?/1`.
- Hard abort: `Task.shutdown(loop_task, :brutal_kill)` kills the loop
  + all linked child tasks; tool tasks are linked to the loop task, so
  they die with it.
- Tool handlers **must** check `AbortRef.aborted?/1` at safe points OR
  pass it through to children that do (`Task.Supervisor.async_stream
  with timeout`, etc.).

Cleanup on abort[^abort-cleanup]:
- LLM stream emits `Event.Error{reason: :aborted}`.
- Loop appends a synthetic assistant message with `stop_reason:
  :aborted` + error message.
- Queues are **not** cleared (pi-mono leaves them; next `prompt/2`
  drains them).

---

## 5. Steering + follow-up queues

**Steering** (`steer/2`) enqueues messages that get injected
**between tool-result and next LLM call** in the *same* run[^steer].
**Follow-up** (`follow_up/2`) enqueues messages that get processed
**only after the run would otherwise stop**[^follow-up]. Follow-up
calls during an idle agent **do not wake the session** — they're
picked up by the next `prompt/2` or `continue/1` (agent.ts L344-346).

Queue module[^queue]:

```elixir
defmodule OctoPi.Agent.PendingMessageQueue do
  # Bounded; defaults to 1_000 messages
  # mode :one_at_a_time | :all
  def new(mode, bound \\ 1_000)
  def enqueue(q, msg) :: q | {:error, :full}
  def has_items?(q) :: boolean
  def drain(q) :: {[AgentMessage.t()], q}   # per mode
  def clear(q) :: q
end
```

Drainage points in the loop:
- **Steering**: after `turn_end`, before the next inner iteration
  (agent-loop.ts L218).
- **Follow-up**: after inner loop would exit, before outer-loop break
  (L222).

Mode can be switched at runtime via `OctoPi.Agent.set_steering_mode/2`
(mirrors TS `agent.steeringMode = "all"`).

---

## 6. Hooks

Two hooks at the agent-core layer[^hooks]; the full 20-event
extensions system lives in Phase 6 (`octo-3gv`):

| Hook | When | Can |
|---|---|---|
| `before_tool_call` | after argument validation, before execute | block with reason (→ error result) OR pass through |
| `after_tool_call` | after execute returns | patch any of `content`, `details`, `is_error?`, `terminate?` — omitted fields keep original |

Signature (sync fun, not behaviour):

```elixir
before_tool_call: (context :: before_ctx -> {:block, reason :: String.t()} | :allow)
after_tool_call: (context :: after_ctx -> {:patch, map()} | :unchanged)
```

Both receive the tool-call details and the abort ref. Exceptions in
hooks are caught and surface as synthetic error tool-results
(L560-566, L638-641). Awaited synchronously — slow hooks slow the
whole run.

---

## 7. Subscribers + events

`agent.subscribe(listener)` adds a fun that is **awaited in
subscription order** before the next event fires[^sub-barrier]:

```typescript
for (const listener of this.listeners) { await listener(event, signal); }
```

That's the **listener barrier** — a sync barrier across potentially
many observers. Porting it to OTP cleanly is §10's biggest problem.

Our shape:

```elixir
OctoPi.Agent.subscribe(session_pid, listener_pid, mode :: :sync | :async)
```

- `:sync` → Session does `GenServer.call(listener_pid, {:event, ev})`
  sequentially, honoring the barrier. Timeout 5s per listener.
- `:async` → Session does `send(listener_pid, {:event, ev})` fire-and-
  forget. For UI / logging / non-critical observers.

Explicit mode in the API makes the cost visible. A misbehaving
`:sync` listener can slow the whole session — but that's the TS
behaviour we're intentionally replicating.

**Events emitted at this layer**[^events]:
- `agent_start`, `agent_end`
- `turn_start`, `turn_end`
- `message_start`, `message_update`, `message_end` (streamed assistant message)
- `tool_execution_start`, `tool_execution_update`, `tool_execution_end`

UI-level events (`message_render`, `session_switch`, …) come from
the coder layer in Phase 3.

---

## 8. Transport pluggability

**Direct** (default): LLM stream goes through `OctoPi.AI.stream/3`
from Phase 1. No code difference from the provider layer.

**Proxy** (deferred): POST a session's `{model, context, options}`
to an upstream HTTP server that runs the provider call on behalf of
the client and SSE-streams events back. Reduces bandwidth by
omitting `partial` and reconstructing client-side[^proxy].

Behaviour:

```elixir
defmodule OctoPi.Agent.Transport do
  @callback stream(Model.t(), Context.t(), StreamOptions.t()) :: Enumerable.t(Event.t())
end
```

Providers registered via the core's `ProviderRegistry` (reusing
`octo-42f.5`'s shape). Transport choice per-session in opts.

---

## 9. OTP mapping summary

| TS concept | Elixir/OTP |
|---|---|
| `Agent` class (mutable state + listeners) | `OctoPi.Agent.Session` GenServer |
| `runAgentLoop` | `Task` under `OctoPi.Agent.LoopSupervisor` |
| `streamFn` transport | `@behaviour OctoPi.Agent.Transport` |
| `Promise.all` (parallel tools) | `Task.Supervisor.async_stream_nolink(ordered: false)` |
| `AbortSignal` | abort ref + ETS flag (`OctoPi.Agent.AbortRef`), `Task.shutdown` for hard abort |
| `onUpdate` callback | tool task sends `{:tool_update, call_id, partial}` to Session |
| Listener barrier | Registry of subscribers, per-mode dispatch |
| Steering + follow-up | `OctoPi.Agent.PendingMessageQueue` module, held in Session state |
| Per-tool execution mode | `:execution_mode` field on Tool struct |
| Extensions system (Phase 6) | out of scope here |

Proposed module layout under `apps/octo_pi_agent/lib/octo_pi/agent/`:

```
agent.ex              # public facade: OctoPi.Agent.start_session/prompt/...
session.ex            # Session GenServer
loop.ex               # inner + outer loop (plain function run in a Task)
tool.ex               # %Tool{} struct + Result struct + execute helper
tool_dispatch.ex      # parallel / sequential execution
pending_message_queue.ex
abort_ref.ex          # ETS-backed cooperative flag
event.ex              # AgentEvent union
message.ex            # AgentMessage union (user / assistant / toolResult / custom)
transport.ex          # @behaviour Transport
transport/direct.ex   # default — delegates to OctoPi.AI.stream/3
subscribers.ex        # Registry wrapper with :sync / :async modes
hooks.ex              # before_tool_call / after_tool_call plumbing
application.ex        # Supervisor + Task.Supervisor + telemetry handler + Registry
telemetry/handler.ex  # events: [:octo_pi_agent, :session, :start/:stop],
                      #         [:octo_pi_agent, :turn, :start/:stop],
                      #         [:octo_pi_agent, :tool, :execute/:complete/:error]
```

---

## 10. Hard parts

The 5 things that don't map cleanly and need careful design:

### 10.1 Listener barrier

**TS**: awaits every listener sequentially before firing the next
event[^barrier-hard].

**OTP port**: `GenServer.call` to each `:sync` listener, with a
5-second timeout. `:async` listeners get `send/2`. Explicit mode in
the subscribe API. A listener that times out or crashes becomes a
logged warning, not a session-killer.

### 10.2 Cooperative abort

**TS**: `AbortSignal.aborted` polled in tool code and the LLM
stream[^abort-hard].

**OTP port**: an abort ref (reference) + a read-through ETS flag.
Tools check `OctoPi.Agent.AbortRef.aborted?(ref)` at safe points.
Hard abort via `Task.shutdown(loop, :brutal_kill)` kills everything
linked. Timeouts stay explicit on `GenServer.call` and
`Task.Supervisor.async_stream`.

### 10.3 Mutable `partialMessage` objects

**TS**: the same object reference is mutated as deltas arrive, then
re-emitted[^partial-hard].

**OTP port**: Elixir is immutable; Session state holds the current
partial; events carry a fresh copy (shared structurally where
possible). Subscribers MUST NOT assume identity across events —
compare by field values.

### 10.4 Ordered tool-result emission under parallel execution

**TS**: `Promise.all` finishes, results sorted by assistant-source
index, emitted in order[^order-hard].

**OTP port**: `Task.async_stream(ordered: false)` gives unordered
completion. We collect `{index, result}` tuples, `Enum.sort_by(& &1)`,
then emit. Source order is preserved even when completion order is
not — matches TS semantics, cheaper than ordered streaming.

### 10.5 Hook composition without an extensions system

**TS**: `beforeToolCall` / `afterToolCall` are single callbacks;
pi-coding-agent layers extensions on top[^hook-hard].

**OTP port**: for Phase 2, keep hooks as plain funs in session opts.
Chaining is out of scope; Phase 6 (`octo-3gv`) is where the
behaviour-based extensions system lands.

---

## 11. Tests to port

From `tmp/pi-mono/packages/agent/test/`:

### `agent-loop.test.ts`
Invariants to pin in ExUnit:
- Event order: `agent_start` → `turn_start` → `message_*` →
  `tool_execution_*` → `turn_end` → `agent_end`.
- Loop continues if the assistant message contains tool calls.
- Loop exits if no tool calls and no queued steering/follow-up.
- Tool results are appended to messages in source order after
  parallel execution.
- Sequential execution mode honors per-tool flags.
- Hook `block` result yields an error tool-result.
- Hook `after_tool_call` patch merges field-by-field.

### `agent.test.ts`
- `state.messages` setter copies the array.
- `subscribe/2` returns an unsubscribe closure.
- `:sync` listeners are awaited in registration order.
- `abort/1` mid-stream surfaces `stop_reason: :aborted`.
- `steer/2` queued message appears in the next LLM context.
- `follow_up/2` during idle doesn't wake the session.

Adaptations noted: AbortSignal → abort ref + ETS, EventStream →
Enumerable, listener promises → GenServer.call.

---

## Footnotes

[^session-state]: `tmp/pi-mono/packages/agent/src/types.ts` L257-288; `agent.ts` L158-543
[^public-api]: `agent.ts` L219-299
[^run-loop]: `agent-loop.ts` L155-234
[^stream-fn]: `agent-loop.ts` L240-245, L269; `types.ts` L24-26
[^tool-batching]: `agent-loop.ts` L338-471
[^exit]: `agent-loop.ts` L194-234
[^tool-shape]: `types.ts` L306-330
[^handler-contract]: `agent-loop.ts` L569-604
[^tool-registry]: `agent.ts` L95, L74-78
[^abort-path]: `agent-loop.ts` L269, L522, L571, L613
[^otp-abort]: `RESEARCH.md` §4.5
[^abort-cleanup]: `agent-loop.ts` L194-197; `agent.ts` L474, L481-485
[^steer]: `agent.ts` L252-254; `agent-loop.ts` L218
[^follow-up]: `agent.ts` L257-259, L344-346; `agent-loop.ts` L222-230
[^queue]: `agent.ts` L113-144
[^hooks]: `types.ts` L208-223; `agent-loop.ts` L536-551, L617-641
[^sub-barrier]: `agent.ts` L539-541
[^events]: `types.ts` L349-364
[^proxy]: `proxy.ts` L116-232
[^barrier-hard]: `agent.ts` L539-541
[^abort-hard]: `agent-loop.ts` L269, L522, L571, L613, L577-603
[^partial-hard]: `agent-loop.ts` L296-298, L311-312
[^order-hard]: `agent-loop.ts` L457-464
[^hook-hard]: `types.ts` L208-223; `RESEARCH.md` §8.3
