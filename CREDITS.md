# Credits

## Upstream: pi-mono

`octo_pi` is a ground-up Elixir/OTP port inspired by and architecturally
modeled on [`badlogic/pi-mono`](https://github.com/badlogic/pi-mono) by
Mario Zechner.

- Upstream: <https://github.com/badlogic/pi-mono>
- Version studied during research: **v0.69.0**
- Upstream license: MIT

This is a clean-room reimplementation in Elixir/OTP, not a translation.
The architectural ideas — session as an append-only JSONL event log, the
extension-based tool/steering system, the agent/coder/TUI separation —
come from pi-mono. Where we track upstream's public data format (most
notably the JSONL session format), that is an explicit choice to preserve
cross-compatibility so users can move sessions between `pi` and `octo_pi`.

The MIT license of pi-mono is preserved; see the upstream repository for
its full text.
