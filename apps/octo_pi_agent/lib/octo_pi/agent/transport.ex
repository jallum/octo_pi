defmodule OctoPi.Agent.Transport do
  @moduledoc """
  Behaviour that abstracts how the session reaches an LLM provider.

  Two concrete transports are planned:

    - `OctoPi.Agent.Transport.Direct` (default) — delegates to
      `OctoPi.AI.stream/3`, which dispatches via `ProviderRegistry`
      to whichever Phase 1 provider handles the `Model`'s api atom.
    - Proxy (deferred) — tunnels through an HTTP proxy that runs the
      provider call server-side and streams events back; see
      `tmp/pi-mono/packages/agent/src/proxy.ts` for the upstream.

  Per-session transport via session opts:

      OctoPi.Agent.start_session(model: model, transport: OctoPi.Agent.Transport.Direct, ...)
  """

  alias OctoPi.AI.{Context, Event, Model, StreamOptions}

  @type event_stream :: Enumerable.t(Event.t())

  @callback stream(Model.t(), Context.t(), StreamOptions.t()) :: event_stream()
end
