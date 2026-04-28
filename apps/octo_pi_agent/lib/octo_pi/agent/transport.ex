defmodule OctoPi.Agent.Transport do
  @moduledoc """
  Behaviour that abstracts how the session reaches an LLM provider.

  Two concrete transports are planned:

    - `OctoPi.Agent.Transport.Direct` (default) — delegates to
      `OctoPi.AI.stream_to/5`, which dispatches via `ProviderRegistry`
      to whichever provider handles the `Model`'s api atom.
    - Proxy (deferred) — tunnels through an HTTP proxy that runs the
      provider call server-side and streams events back; see
      `tmp/pi-mono/packages/agent/src/proxy.ts` for the upstream.

  Per-session transport via session opts:

      OctoPi.Agent.start_session(model: model, transport: OctoPi.Agent.Transport.Direct, ...)
  """

  alias OctoPi.AI.Context
  alias OctoPi.AI.Model

  @doc """
  Spawn a producer task that sends `{ref, :event, event}` messages to
  `pid` and finishes with `{ref, :done}`. Returns `{:ok, producer_pid}`.
  """
  @callback stream_to(Model.t(), Context.t(), keyword(), pid(), reference()) :: {:ok, pid()}
end
