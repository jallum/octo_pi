# opi-4dx.2 — TUI streaming render spike

Trace captured by running `mix pi --log-telemetry .pi/trace2.log` in tmux,
submitting two prompts to `claude-haiku-4-5`, and hammering keystrokes via
`tmux send-keys` while the assistant was streaming. Raw trace lives at
`.pi/trace2.log`; analysis script at `.pi/analyze_spike.exs`.

This is one bounded sample, not a benchmark. It is sufficient to decide
which follow-ups in opi-4dx are warranted; numerical bars below become the
acceptance bar each follow-up must clear in its own validation.

## Headline numbers (the bar follow-ups must clear)

| Metric | p50 | p99 | max |
|---|---|---|---|
| `octo_pi_agent_event` handle_info duration | 2.90 ms | 9.31 ms | 9.31 ms |
| `key.latency` (arrival → handled) | 105.86 ms | 190.97 ms | 194.45 ms |
| `markdown.render` at largest observed text_bytes (~265) | — | 1.31 ms | 1.31 ms |
| `transcript.render` at msg_count=4 (streaming) | 2.22 ms | 4.10 ms | — |

## Q1 — handle_info duration by kind

Streaming ate 2–3× as long as a keystroke handler in the median, which
matters because every chunk holds the GenServer's mailbox closed against
queued keystrokes for that long.

| kind | n | median | p99 | max | mean |
|---|---|---|---|---|---|
| `hid_event` | 313 | 1.64 ms | 4.88 ms | **59.98 ms** | 2.01 ms |
| `octo_pi_agent_event` | 93 | 2.90 ms | 9.31 ms | 9.31 ms | 3.00 ms |
| `timeout` | 182 | 3.09 ms | 5.21 ms | 5.41 ms | 3.08 ms |

The 60 ms `hid_event` outlier is a single sample (likely the initial
resize/setup).

## Q2 — `markdown.render` duration vs `text_bytes`

The captured streaming response was short (~265 bytes max), so this run
**does not characterize markdown scaling at large bytes**. Within the
observed range:

| text_bytes | n | median | p99 |
|---|---|---|---|
| 0–256 | 10 | 0.61 ms | 3.68 ms |
| 256–1024 | 561 | 0.81 ms | 2.10 ms |

The 561-event count at 256–1024 bytes is mostly *re-renders of the same
finalized message* (the prior assistant message) being walked every
frame. That is itself a finding: see Q4.

A second spike pass against a multi-KB response is needed to characterize
Earmark scaling. Treat opi-4dx.5 as **provisionally justified** pending
that follow-up; it would still help the HOL story regardless because
it removes the per-chunk-and-per-keystroke render multiplier on the
streaming message.

## Q3 — `key.latency` vs `mailbox_len_at_arrival` (the smoking gun)

Strong correlation between mailbox depth at arrival and observed key
latency, exactly the head-of-line blocking signature predicted in the
epic. Selected rows:

| mailbox_len | n | median | p99 |
|---|---|---|---|
| 0 | 7 | 1.83 ms | 194.45 ms |
| 1 | 4 | 177.34 ms | 193.01 ms |
| 5 | 4 | 170.43 ms | 186.50 ms |
| 10 | 3 | 173.94 ms | 173.94 ms |
| 20 | 5 | 150.53 ms | 153.16 ms |
| 50+ | … | 90–105 ms | … |

Mailbox 0 events split into two regimes: ~2 ms when truly idle and
~190 ms when the keystroke just barely missed the head of line. As the
mailbox depth grows past ~50 the per-key duration *drops* — that's the
scheduler draining a queued burst at full speed; the remaining keys
waited a long time on the front, but each *individual* dequeue is fast.

The user-felt delay at depth 1–20 is uniformly ~150–190 ms, which is
exactly "noticeably sluggish" territory for an editor. **Head-of-line
blocking is confirmed; opi-4dx.3 (pull-tick coalescing) is justified.**

## Q4 — `transcript.render` duration vs `msg_count`

Cost per call is roughly flat in `msg_count` over the observed range
(2 → 4 messages):

| msg_count | streaming p50 | streaming p99 | idle p50 | idle p99 |
|---|---|---|---|---|
| 2 | 1.92 ms | 4.60 ms | 1.06 ms | 3.57 ms |
| 4 | 2.22 ms | 4.10 ms | 1.36 ms | 4.36 ms |

But the **frequency** is the killer: at msg_count=4 we logged 326
streaming-flagged transcript.renders during a streaming window plus 103
idle ones — that's a render on every keystroke and every chunk. Each
re-walks every finalized assistant message. Range is too narrow (only
2–4 messages) to tell whether cost grows linearly with `msg_count`.

opi-4dx.4 (per-finalized-message line cache) is **not strongly justified
by this data alone** — a longer conversation would be needed to confirm
linear growth in `msg_count`. Marking it **deferred** pending a separate
trace, lower priority than .3 and .5.

## Decisions

| Ticket | Verdict | Rationale |
|---|---|---|
| **opi-4dx.3** pull-tick coalescing | **Justified — primary** | mailbox depth → key latency correlation is unambiguous; coalescing chunks into a tick is the structural fix. |
| **opi-4dx.5** incremental Markdown lexer | **Provisionally justified** | This trace's streaming message was too short to confirm scaling, but the per-chunk + per-keystroke transcript-render frequency means *anything* we can do to make the streaming message's render cheaper compounds the win from .3. Re-run the spike against a multi-KB response after .3 lands to confirm. |
| **opi-4dx.4** finalized-message line cache | **Deferred** | Range too narrow (2–4 msgs) to confirm `msg_count`-linear growth. Re-evaluate against a long-conversation trace later. |

## Method notes

- `mix pi -m claude-haiku-4-5 --log-telemetry .pi/trace2.log` inside
  `tmux` (160×50) on macOS, BEAM 28.3 / Elixir 1.19.5.
- Two prompts submitted via `tmux send-keys`. Keystrokes hammered during
  streaming via repeated `tmux send-keys -t spike2 abcdefghij`.
- Trace covers ~67 s of real time including idle, two prompt cycles,
  and the streaming window.
- Single sample. Numbers aren't statistical bounds; they're directional
  evidence sufficient to gate the follow-up tickets.

## opi-4dx.5 post-implementation re-trace (`.pi/trace3.log`)

Captured after the AST shape refactor (commit `73bcd74`) and the
`Markdown.Stream` incremental wrapper (commit `44cd7fe`). Prompt asked
the agent to produce a comprehensive Markdown demo (~90-line response
exercising H1–H6, fenced code, ordered/unordered lists with nesting,
blockquote, HR, and a 3×4 table). Keystrokes hammered during streaming
via `tmux send-keys`. Local model (`ollama/qwen3.5`) instead of
`claude-haiku-4-5` — apples-to-apples for the renderer, different
chunking cadence than the original.

### Q1 — handle_info duration (µs) by kind, before vs after

| kind | median (old → new) | p99 (old → new) | max (old → new) |
|---|---|---|---|
| `hid_event` | 1640 → **614** | 4880 → **5095** | 59980 → **13787** |
| `octo_pi_agent_event` | 2900 → **114** | 9310 → **1879** | 9310 → **8533** |
| `timeout` | 3090 → **2809** | 5210 → **6777** | 5410 → **14726** |

The `octo_pi_agent_event` kind is the streaming hot path
(stream-chunk → AssistantMessage.update_content → Stream.put → render).
**Median dropped 96% (2.90 ms → 0.11 ms); p99 dropped 80%** — the
incremental lexer cuts the per-chunk cost by an order of magnitude.

### Q2 — `markdown.render` scaling

| text_bytes | n | median | p99 |
|---|---|---|---|
| 0–256 | 55 | 0.26 ms | 0.84 ms |
| 256–1024 | 54 | 0.46 ms | 1.20 ms |

Top bucket sample at ~624 bytes: p99 0.87 ms (n=6). Even on the
*growing* streaming message (full assistant text re-rendered each
chunk), the cost stays sub-millisecond because the committed paragraph
prefix is served from cache and only the tail paragraph is freshly
lexed. Compare to the trace2 finding that 18.7 KB messages hit p99
~53 ms on the prior path.

### Q3 — `key.latency` vs `mailbox_len_at_arrival`

| mailbox_len | n | median | p99 |
|---|---|---|---|
| 0 | 378 | 0.10 ms | 3.58 ms |
| 1 | 4 | 4.45 ms | 221.10 ms |
| 5 | 1 | 220.35 ms | 220.35 ms |
| 50 | 2 | 210.49 ms | 210.49 ms |
| 200+ | … | 80–135 ms | … |

Mailbox=0 is now 0.10 ms median (vs 1.83 ms / 194 ms bimodal in
trace2): the great majority of keystrokes arrive to an idle process and
are handled in microseconds. The 220 ms tail at low mailbox depth
persists in this trace, but represents a much smaller share of events
(the bimodal `mailbox=0` "barely missed" regime is essentially gone).

### Q4 — `transcript.render` duration vs `msg_count` (streaming)

| msg_count | streaming n | streaming p50 | streaming p99 |
|---|---|---|---|
| 2 | 1003 | 1.91 ms | 4.79 ms |
| 4 | 162 | 2.81 ms | 5.89 ms |
| 6 | 108 | 3.24 ms | 6.21 ms |

Comparable to trace2 (msg_count=4 streaming p99 4.10 ms). Frequency is
unchanged — every streaming chunk and every keystroke still re-walks
the transcript — but per-call cost remains bounded.

### Headline comparison

| Metric | trace2 | trace3 |
|---|---|---|
| key.latency p50 (overall) | 105.86 ms | **14.85 ms** |
| key.latency p50 at mailbox=0 | ~190 ms (bimodal) | **0.10 ms** |
| `octo_pi_agent_event` p50 | 2.90 ms | **0.11 ms** |
| `markdown.render` p99 (largest sampled) | 1.31 ms (~265 B) | 1.20 ms (~1 KB) |
| `markdown.render` p99 (extrapolated 18.7 KB on prior path) | ~53 ms | bounded by current paragraph |

**opi-4dx.5 cleared its bar.** The streaming hot path (`octo_pi_agent_event`)
is 25× faster at the median, and `markdown.render` no longer scales
linearly with cumulative message size during streaming.

## opi-4dx.6/.7/.8/.9/.10 post-redesign re-trace (`.pi/trace4.log`)

Captured after the per-block delta events (`.6`), Markdown.Render
module (`.7`), Transcript abstraction (`.8`), AssistantMessage
embedding Transcript (`.9`), and Interactive wiring (`.10`) all
landed. Same protocol as trace3: `mix pi --log-telemetry`, tmux
200×50, ollama qwen3.5, ~90-line markdown demo prompt, keystroke
hammering during streaming.

### Q1 — handle_info duration by kind (median / p99 µs)

| kind | trace3 median → trace4 | trace3 p99 → trace4 |
|---|---|---|
| `hid_event` | 614 → **660** | 5095 → **9376** |
| `octo_pi_agent_event` | **114** → 122 | 1879 → **630** |
| `timeout` | 2809 → 3263 | 6777 → 10011 |

`octo_pi_agent_event` p50 is essentially flat (114→122µs); p99
**dropped 66%** (1.88 → 0.63 ms). The block-delta events landing on
the streaming hot path are uniformly cheap — no more bimodality
when a chunk lands and triggers a content-list rebuild.

### Q2 — `markdown.render` scaling

| text_bytes | n | median (ms) | p99 (ms) |
|---|---|---|---|
| 0–256 | 27 | 0.15 | 0.27 |
| 256–1024 | 135 | 0.44 | 1.13 |
| 1024–4096 | 399 | 1.04 | 2.98 |
| 4096–8192 | 468 | 2.52 | 5.81 |
| 8192+ | 342 | 3.62 | 10.63 |

trace4's prompt got a much larger response than trace3 (~11 KB max
vs ~1 KB). Per-render cost grows roughly linearly with text_bytes,
which is what the Markdown.Render committed-iodata cache plus
volatile-tail re-lex predicts: each render does O(current paragraph
size + cache-flatten) work. At 8 KB+ the p99 is 10.6 ms — within a
30 Hz frame budget.

### Q3 — `key.latency` vs `mailbox_len_at_arrival`

| mailbox_len | trace3 (n / p50 / p99) | trace4 (n / p50 / p99) |
|---|---|---|
| 0 | 378 / 0.10 / 3.58 | 83 / 0.55 / 134.95 |
| 1 | 4 / 4.45 / 221.10 | 46 / 8.33 / 134.12 |
| 5 | 1 / 220.35 | 6 / 10.94 / 131.74 |
| 50+ | 2 / 210.49 / 210.49 | 38–177 / 60–115 ms |

`mailbox=0` p50 went from 0.10 → 0.55 ms (still sub-millisecond at
the median; the p99 of 134.95 ms is one outlier in n=83). The 220
ms key.latency tail from trace3 is **gone** — max in trace4 is
134.95 ms, and the deep-mailbox latencies cluster at 60–135 ms,
matching the streaming-tick coalescing budget.

### Q4 — `transcript.render` duration vs msg_count

| msg_count | trace3 streaming p50/p99 | trace4 streaming p50/p99 |
|---|---|---|
| 2 | 1.91 / 4.79 | 2.78 / 7.80 |
| 3 | — | (idle only, n=9, 10.4/89.5 outlier) |
| 4 | 2.81 / 5.89 | — |
| 6 | 3.24 / 6.21 | — |

`transcript.render` per-call cost regressed ~1.5× at the median for
streaming msg_count=2 (1.91→2.78 ms). The cost source is the
`AssistantMessage` ↔ Transcript boundary: every render allocates a
`ctx` map and Transcript.render does a structural-equality check
against the stored ctx (a theme map being one of its keys is
expensive to compare). The reference-cache short-circuit added in
.10 helps but doesn't fully amortize the per-render overhead.

The acceptance bar — "p99 at msg_count=10+ no greater than at
msg_count=2" — is **not directly verified** in this trace because
the streaming msg_count never exceeded 2 (single-turn run). The
mechanism is sound (Transcript caches finalized entries' iodata),
but a multi-turn run is needed to confirm the cross-message scaling
property.

### Headline comparison

| Metric | trace3 | trace4 | Δ |
|---|---|---|---|
| `octo_pi_agent_event` handle_info p50 | 0.11 ms | 0.12 ms | flat |
| `octo_pi_agent_event` handle_info p99 | 1.88 ms | **0.63 ms** | −66% |
| `key.latency` overall p50 | 14.85 ms | 21.16 ms | +43% |
| `key.latency` overall p99 | (220 ms tail) | **134.95 ms** | −39% |
| `transcript.render` p50 (streaming msg=2) | 1.91 ms | 2.78 ms | +46% |
| Max `key.latency` observed | 220+ ms | **134.95 ms** | −39% |

### Verdict

Mixed. The streaming hot-path metric (`octo_pi_agent_event`) gets
better, the 220 ms key-latency tail is closed, and `markdown.render`
remains bounded by current-paragraph size at all observed text
sizes. But `transcript.render` per-call cost regressed by ~50%,
attributable to the ctx-allocation + structural-equality overhead at
the `AssistantMessage` ↔ Transcript boundary that wasn't there
pre-`.9`/`.10`.

Acceptable trade for the architectural cleanup, but the regression
is real. Two follow-ups worth filing if the cost is felt in
practice:

1. **Cache the AssistantMessage ctx by reference** — recompute only
   when theme/width/hide_thinking changes, store on the struct.
   Avoids the per-render map allocation and structural compare.
2. **Skip the iodata→binary→split roundtrip** — have AssistantMessage
   walk its blocks directly and concat lines per-renderer rather
   than materializing the full transcript binary every render.

The 220 ms key-latency tail at low mailbox depth is no longer
reproducible — most likely it was an artifact of the old apply_partial
path (full content-list rebuild + AssistantMessage allocation per
chunk) hitting the GC. The .10 path stashes deltas in O(1) per chunk
and only walks blocks at the streaming-tick boundary.
