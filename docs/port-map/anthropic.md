# Port map: Anthropic provider

Porting spec for the `octo_pi_ai` Anthropic provider. Canonical reference:
[`pi-mono` v0.69.0](https://github.com/badlogic/pi-mono), shallow-cloned at
`tmp/pi-mono/`. All line citations are into that tree.

**Primary sources (read first):**
- `tmp/pi-mono/packages/ai/src/providers/anthropic.ts` — provider + SSE parser + decoder
- `tmp/pi-mono/packages/ai/src/utils/event-stream.ts` — queue-based async iterator
- `tmp/pi-mono/packages/ai/src/utils/json-parse.ts` — JSON repair + partial parse
- `tmp/pi-mono/packages/ai/src/stream.ts` — dispatcher, `streamSimple` shim
- tests under `tmp/pi-mono/packages/ai/test/anthropic-*.test.ts`

---

## 0. What we're building

`OctoPi.AI.stream(model, context, opts)` returns a lazy Elixir `Stream` of
canonical events, terminated by either `:done` or `:error`. The HTTP client
(Req) is used as a **byte pipe only**: SSE framing, JSON repair, Anthropic
event decoding, and quirk normalization are all our code. That's how
pi-mono does it too — the Anthropic TS SDK is a thin header/signing helper;
all the streaming machinery lives in `anthropic.ts`[^machinery].

---

## 1. HTTP request

### 1.1 Endpoint
- `POST https://api.anthropic.com/v1/messages`
- Body JSON includes `"stream": true`.
- Custom `baseUrl` per model config is supported upstream but not needed
  for Phase 1.

### 1.2 Auth (Phase 1 = API key only)

Three variants exist upstream; we ship only (a). (b) and (c) defer.

(a) **API key**[^envkey]
- `x-api-key: <key>` header
- Key source: `ANTHROPIC_API_KEY` env var, falling back to `ANTHROPIC_OAUTH_TOKEN`

(b) **OAuth** — detected when key contains `"sk-ant-oat"`[^oauth-detect].
Adds Bearer auth, `user-agent: claude-cli/2.1.75`, `x-app: cli`, a mandatory
identity system prompt (`"You are Claude Code…"`), and extra betas. Also
requires Claude-Code tool-name case-normalization in both directions[^oauth].

(c) **GitHub Copilot** — Bearer auth, subset of Anthropic betas[^copilot].

### 1.3 Fixed headers (all variants)
- `anthropic-version: 2023-06-01`
- `content-type: application/json`
- `accept: application/json`
- `anthropic-dangerous-direct-browser-access: true` (harmless for server-side; pi-mono sends it[^dab])

### 1.4 Beta features (comma-joined in `anthropic-beta`)
- Minimum Phase 1 request: no `anthropic-beta` header needed.
- `interleaved-thinking-2025-05-14`: only for models *without* adaptive
  thinking (pre-Opus 4.6) when `interleavedThinking=true`[^interleaved].
- `fine-grained-tool-streaming-2025-05-14`: pi-mono sends for OAuth by
  default[^fgts]. Skip for Phase 1.

### 1.5 Body shape[^body]

```json
{
  "model": "claude-opus-4-5",
  "messages": [...],
  "max_tokens": <floor(model.maxTokens / 3)>,
  "stream": true,
  "system": [...],            // optional; may carry cache_control
  "tools": [...],              // optional; each gets eager_input_streaming: true
  "temperature": 0.7,          // OMIT when thinking is enabled
  "metadata": { "user_id": "..." },
  "tool_choice": { "type": "..." },
  "thinking": { ... },         // if model.reasoning supported
  "output_config": { "effort": "..." }  // adaptive thinking only
}
```

Normalizations to replicate:
- Tool-call id regex: `^[a-zA-Z0-9_-]+$`, max 64 chars. Offending ids are
  sanitized by `id.replace(/[^a-zA-Z0-9_-]/g, "_").slice(0, 64)`[^toolid].
- Tool input schema coerced to `{type: "object", properties, required}`[^tool-schema].
- Each tool definition gets `eager_input_streaming: true`[^eager].
- `temperature` omitted whenever thinking is enabled[^temp].

### 1.6 Thinking modes
| Capability | Body |
|---|---|
| Adaptive (Opus 4.6+, Sonnet 4.6+) | `thinking: {type: "adaptive", display: "summarized"}` + `output_config: {effort}`[^adaptive] |
| Budget (older Claude 4) | `thinking: {type: "enabled", budget_tokens: N, display: "summarized"}`[^budget] |
| Disabled | `thinking: {type: "disabled"}`[^disabled] |

`display` defaults to `"summarized"` (not the API default `"omitted"`) for
compat with older Claude 4[^display-default]. Adaptive-capable detection is
by substring match on model id (`opus-4-6`, `opus-4.6`, `opus-4-7`,
`opus-4.7`, `sonnet-4-6`, `sonnet-4.6`)[^adaptive-detect].

### 1.7 Cache control — defer
Placement rules live in `anthropic.ts` L1054-1100[^cache]: last system
block, last content block of last user message, last tool definition.
`ttl: "1h"` only for `api.anthropic.com` hosts. Skip for Phase 1.

### 1.8 Message conversion
Port `convertMessages` / `convertContentBlocks`[^convert]. Notable:
consecutive tool-result messages are bundled into a single user message
whose content is the array of tool-result blocks[^bundle].

**Elixir module:** `OctoPi.AI.Anthropic.Request` — pure `build/3`.

---

## 2. Transport

Upstream reads a `ReadableStream<Uint8Array>` via `.asResponse()`[^transport].
Equivalent in Elixir:

```elixir
Req.post(url,
  headers: headers,
  json: body,
  into: :self,          # chunks as messages to the owner process
  receive_timeout: :infinity
)
```

The owner is our `Producer` GenServer (§7). Chunks arrive as
`{Req.Response, ref, {:data, chunk}}` messages. No HTTP-level retry.

---

## 3. SSE parser

Module: **`OctoPi.AI.SSE`**. Pure `decode_chunk(state, bytes) :: {events, state'}`.

### 3.1 Byte → string
Accumulate raw bytes in a buffer. Only convert a prefix to a UTF-8 string
after a complete line is located — preserves incomplete multi-byte chars at
chunk boundaries[^decoder]. Elixir: keep `binary` in state; match on
`\r\n` / `\r` / `\n` on the bytes directly, then `:unicode.characters_to_binary/1`
on the completed line.

### 3.2 Line breaking (exact)
- Scan for first `\r` or `\n`[^linebreak-find].
- If `\r` followed by `\n`, consume both as one boundary; else consume the
  single byte[^linebreak-consume].

### 3.3 Event accumulation
State per event: `%{event: "message", data: []}`.

Per line[^sse-accum]:
- Empty line → flush `{:event, state.event, Enum.join(state.data, "\n")}`, reset state.
- Starts with `:` → comment, drop[^comment].
- No `:` → treat whole line as field name, value is `""`[^no-colon].
- `field:value` → split on first `:`; strip one leading space from value[^colon-split].
- Field `event` → overwrite `state.event`.
- Field `data` → append value to `state.data`.
- `id`, `retry`, others → drop.

### 3.4 Before handing to Anthropic decoder
Two special SSE events[^ping-err]:
- `event: "ping"` → silently drop (no canonical event).
- `event: "error"` → raise `{:anthropic_error, data_binary}`; producer catches.

Everything else → JSON-parse `data` via `parse_json_with_repair/1` (§4.1)
→ pass to decoder.

### 3.5 Stream end
Final `TextDecoder` flush equivalent: if any incomplete UTF-8 remains in
the buffer at EOF, drop it (mirrors the TS behavior[^final-flush]).

---

## 4. Partial JSON

Module: **`OctoPi.AI.PartialJson`**.

### 4.1 `parse_with_repair/1 :: {:ok, term} | {:error, reason}`
Used for whole SSE frames that may contain raw control chars inside strings[^repair-purpose].

Strategy[^json-repair]:
1. `Jason.decode(binary)` → on success, return.
2. Run repair pass:
   - Inside string contexts, escape raw control chars (`\n` → `\\n`, etc.)
   - Double-backslash before invalid escape sequences
3. If repair changed nothing, return the original error.
4. Otherwise `Jason.decode(repaired)`; return its result as-is.

### 4.2 `parse_streaming/1 :: map`
Used for tool-call `partial_json` accumulator. **Always returns a map**,
never errors[^streaming-json].

1. Try `parse_with_repair/1`; if it yields a map, return it.
2. Try a tolerant partial-parse: close unterminated strings with `"`, drop
   trailing commas, add enough `}`/`]` to balance brackets, then
   `parse_with_repair/1`. On success (map), return.
3. Otherwise return `%{}`.

pi-mono uses the `partial-json` npm lib for step 2; no Elixir equivalent
exists, so we write ~60-80 lines of tolerant parsing. Semantics: best-effort,
never raise.

---

## 5. Canonical event union

Module: **`OctoPi.AI.Event`** + structs `AssistantMessage`, `ToolCall`,
`Usage`.

### 5.1 Lifecycle (in order)[^ts-events]

```
{:start,           %{response_id, usage, cost, content: [], partial}}
  ...interleaved per content block...
{:text_start,      %{content_index, partial}}
{:text_delta,      %{content_index, delta: binary, partial}}
{:text_end,        %{content_index, content: binary, partial}}
{:thinking_start,  %{content_index, partial}}
{:thinking_delta,  %{content_index, delta: binary, partial}}
{:thinking_end,    %{content_index, content: binary, partial}}
{:toolcall_start,  %{content_index, partial}}
{:toolcall_delta,  %{content_index, delta: binary, partial}}  # raw json fragment
{:toolcall_end,    %{content_index, tool_call: %ToolCall{}, partial}}
  ...then one terminal event...
{:done,            %{reason: :stop | :length | :tool_use, message: %AssistantMessage{}}}
  OR
{:error,           %{reason: :error | :aborted, message: %AssistantMessage{}}}
```

`partial` is the in-progress `AssistantMessage` at that moment. This lets
consumers render state without tracking deltas themselves.

### 5.2 Stop reason map[^stop-reason]

| Anthropic | Canonical |
|---|---|
| `end_turn`, `stop_sequence`, `pause_turn` | `:stop` |
| `max_tokens` | `:length` |
| `tool_use` | `:tool_use` |
| `refusal`, `sensitive` | `:error` |
| any unknown value | **raise** — do not silently drop[^unknown-stop] |

---

## 6. Anthropic → canonical decoder

Module: **`OctoPi.AI.Anthropic.Decoder`**. Input: one parsed Anthropic SSE
event + current state. Output: zero or more canonical events + new state.
State = `%AssistantMessage{}` under construction.

### 6.1 `message_start`[^msg-start]
- `response_id = message.id`.
- Seed usage from `message.usage` (fields may be missing → 0).
- `total = input + output + cache_read + cache_creation` (Anthropic never
  sends `total_tokens`)[^total].
- Compute cost immediately.
- Emit `:start`.

### 6.2 `content_block_start` (dispatch on `content_block.type`)
- `text` → push `%{type: :text, text: "", index}`; emit `:text_start`[^text-start].
- `thinking` → push `%{type: :thinking, thinking: "", signature: "", index}`;
  emit `:thinking_start`[^thinking-start].
- `redacted_thinking` → push `%{type: :thinking, thinking: "[Reasoning redacted]",
  signature: content_block.data, redacted: true, index}`; emit `:thinking_start`[^redacted].
- `tool_use` → push `%ToolCall{id, name, arguments: %{}, partial_json: "", index}`;
  emit `:toolcall_start`[^toolcall-start]. (OAuth needs reverse tool-name
  normalization — deferred.)

### 6.3 `content_block_delta` (dispatch on `delta.type`)
- `text_delta` → `block.text += delta.text`; emit `:text_delta`[^text-delta].
- `thinking_delta` → `block.thinking += delta.thinking`; emit `:thinking_delta`[^think-delta].
- `signature_delta` → `block.signature += delta.signature`; **no canonical
  event emitted** — used only for multi-turn replay[^sig-delta].
- `input_json_delta` → `block.partial_json += delta.partial_json`;
  `block.arguments = parse_streaming(block.partial_json)`; emit
  `:toolcall_delta`[^json-delta].

### 6.4 `content_block_stop`[^cbs]
- Drop the `index` field from the block.
- `text` → emit `:text_end` with final `content`.
- `thinking` → emit `:thinking_end` with final `content`.
- `tool_use` → one final reparse of `partial_json` into `arguments`; drop
  the `partial_json` field; emit `:toolcall_end` with the finalized `%ToolCall{}`.

### 6.5 `message_delta`[^mdelta]
- `delta.stop_reason` → map → set `state.stop_reason`.
- `delta.usage` → **merge only non-null fields**. This preserves
  `input_tokens` from `message_start` when proxies omit it here[^preserve-input].
- Recompute total + cost. **No event emitted.**

### 6.6 `message_stop`
Ignored — the producer exits the loop when the HTTP body ends.

### 6.7 End-of-stream[^end-of-stream]
After the SSE loop exits cleanly:
- `state.stop_reason in [:error, :aborted]` → emit `:error`.
- otherwise → emit `:done`.

**Uncaught exception in the loop**: producer sets
`stop_reason = if aborted?, do: :aborted, else: :error`, puts the exception
message in `error_message`, emits `:error`, terminates the stream[^error-catch].
**Errors never escape the Stream boundary** — callers always see a
well-formed terminal event.

---

## 7. Public API + producer

```elixir
OctoPi.AI.stream(model, context, opts \\ []) :: Stream.t()
```

Options (Phase 1):
- `:signal` — a pid; aborting = killing that pid (we monitor it)
- `:max_tokens`, `:temperature`, `:thinking_enabled`, `:effort`, `:tool_choice`, ...

### 7.1 Architecture
1. `OctoPi.AI.stream/3` starts a `Producer` GenServer (unnamed, linked to caller).
2. Producer calls `Req.post(url, into: :self, ...)`.
3. Producer receives `{Req.Response, ref, {:data, chunk}}` messages,
   feeds them to `OctoPi.AI.SSE.decode_chunk/2`, pipes parsed events into
   `OctoPi.AI.Anthropic.Decoder.decode/2`, and sends each canonical event
   as a message to the caller.
4. `Stream.resource/3` on the caller side: `receive` → yield.

pi-mono's `EventStream` does essentially this with a JS queue[^ts-event-stream];
we get it for free with message-passing + `Stream.resource/3`.

### 7.2 Cancellation
Two ways to abort a stream, both idempotent:
1. **Consumer halts**: `Stream.take/2`, `Enum.take_while/2`, etc. eventually
   terminate the resource; `Stream.resource/3`'s `after` sends `:halt` to
   the producer.
2. **External abort**: caller kills `:signal` pid (or the producer directly).

Either way: producer exits → Req's Finch connection is released (Req is
process-linked) → socket closes → downstream events are dropped. No leaked
sockets, no dangling SSE state. This is structurally simpler than the
upstream two-path abort (signal into fetch + pre-read `signal?.aborted`
poll)[^ts-cancel].

---

## 8. Deferred to later phases

Flagged so we don't rediscover them:

- **OAuth auth** — detection, refresh, identity system prompt, Claude-Code
  tool-name casing (forward + reverse)[^oauth-scope]
- **GitHub Copilot auth variant**[^copilot]
- **Prompt caching** — placement rules + ttl logic[^cache-defer]
- **Thinking modes beyond the simplest** — interleaved/adaptive/budget
  detection and config shaping[^thinking-defer]
- **Cross-provider message transform** — tool-id renormalization across
  providers, thinking-block replay rules, orphaned-tool-call synthetic
  injection, errored-message drop[^replay]
- **Cost calculation** — leave at 0 for Phase 1 or use a simple table.

---

## 9. Proposed module layout

```
apps/octo_pi_ai/lib/octo_pi/ai/
├── event.ex                 # § 5  canonical event + AssistantMessage/ToolCall/Usage structs
├── provider.ex              # § 7  @behaviour OctoPi.AI.Provider
├── sse.ex                   # § 3  pure SSE parser
├── partial_json.ex          # § 4  parse_with_repair/1, parse_streaming/1
├── stream.ex                # § 7  public entry + Producer GenServer
└── anthropic/
    ├── request.ex           # § 1  build/3
    ├── auth.ex              # § 1.2 API-key header only (Phase 1)
    ├── decoder.ex           # § 6  Anthropic → canonical
    └── provider.ex          # provider impl wiring the above
```

---

## Footnotes

[^machinery]: anthropic.ts L300-612
[^envkey]: env-api-keys.ts L72-74
[^oauth-detect]: anthropic.ts L723-725
[^oauth]: anthropic.ts L771-790, L827-841, L501-503, L1008
[^copilot]: anthropic.ts L739-763
[^dab]: anthropic.ts L794-807
[^interleaved]: anthropic.ts L735-736, L741-742, L766-768
[^fgts]: anthropic.ts L740-743
[^body]: anthropic.ts L812-909
[^toolid]: anthropic.ts L60-62, L913-915
[^tool-schema]: anthropic.ts L1095-1099
[^eager]: anthropic.ts L1094
[^temp]: anthropic.ts L853-856
[^adaptive]: anthropic.ts L869-880
[^budget]: anthropic.ts L882-887
[^disabled]: anthropic.ts L889-891
[^display-default]: anthropic.ts L867-868
[^adaptive-detect]: anthropic.ts L643-653
[^cache]: anthropic.ts L1054-1100
[^convert]: anthropic.ts L931-1050
[^bundle]: anthropic.ts L1018-1050
[^transport]: anthropic.ts L300-357, L447-449
[^decoder]: anthropic.ts L305, L320, L332
[^linebreak-find]: anthropic.ts L271-281
[^linebreak-consume]: anthropic.ts L283-298
[^sse-accum]: anthropic.ts L236-266
[^comment]: anthropic.ts L251-253
[^no-colon]: anthropic.ts L255-260
[^colon-split]: anthropic.ts L255-260
[^ping-err]: anthropic.ts L368-374
[^final-flush]: anthropic.ts L332
[^repair-purpose]: anthropic.ts L377
[^json-repair]: json-parse.ts L32-95
[^streaming-json]: json-parse.ts L104-124
[^ts-events]: anthropic.ts L451-623
[^stop-reason]: anthropic.ts L1105-1125
[^unknown-stop]: anthropic.ts L1123
[^msg-start]: anthropic.ts L458-468
[^total]: anthropic.ts L466-467
[^text-start]: anthropic.ts L470-477
[^thinking-start]: anthropic.ts L479-486
[^redacted]: anthropic.ts L487-496
[^toolcall-start]: anthropic.ts L498-509
[^text-delta]: anthropic.ts L516-522
[^think-delta]: anthropic.ts L528-534
[^sig-delta]: anthropic.ts L549-555
[^json-delta]: anthropic.ts L540-547
[^cbs]: anthropic.ts L561-587
[^mdelta]: anthropic.ts L591-610
[^preserve-input]: anthropic.ts L593-594
[^end-of-stream]: anthropic.ts L614-623
[^error-catch]: anthropic.ts L624-633
[^ts-event-stream]: event-stream.ts L4-82
[^ts-cancel]: anthropic.ts L311-313, L447-449, L624-633
[^oauth-scope]: anthropic.ts L771-790, L827-841
[^cache-defer]: anthropic.ts L1054-1100
[^thinking-defer]: anthropic.ts L643-680, L869-891
[^replay]: transform-messages.ts L64-194
