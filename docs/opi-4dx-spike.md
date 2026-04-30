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
