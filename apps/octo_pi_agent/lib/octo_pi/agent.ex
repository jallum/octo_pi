defmodule OctoPi.Agent do
  @moduledoc """
  Phase 2 — the stateful agent kernel. Ported from pi-agent-core.

  Public API and Session GenServer land in `octo-z1d.2`; this module
  currently just houses the app's contract types (see `OctoPi.Agent.*`
  submodules):

    - `Message` / `Message.Custom` — transcript message union
    - `Event` / `Event.*` — canonical event union emitted by a run
    - `Tool` / `Tool.Result` / `Tool.Handler` — tool definition + contract
    - `PendingMessageQueue` — steering / follow-up queue (struct only; impl in z1d.5)
    - `Session.State` — session GenServer state (struct only; impl in z1d.2)
    - `Transport` / `Transport.Direct` — pluggable LLM transport
    - `AbortRef` — cooperative cancellation flag

  See `docs/port-map/agent.md` for the full porting spec.
  """
end
