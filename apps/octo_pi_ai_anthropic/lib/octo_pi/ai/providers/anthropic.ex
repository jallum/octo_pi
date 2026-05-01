defmodule OctoPi.AI.Providers.Anthropic do
  @moduledoc """
  Anthropic Messages provider. Implements `OctoPi.AI.Api` by
  spawning an `OctoPi.AI.Providers.Anthropic.Producer` per call.
  """

  @behaviour OctoPi.AI.Api

  alias OctoPi.AI.Providers.Anthropic.Producer

  @impl true
  def stream_to(model, context, opts, pid) do
    Producer.start(%{
      model: model,
      context: context,
      opts: opts,
      caller: pid,
      req_overrides: Application.get_env(:octo_pi_ai, :req_overrides, [])
    })
  end
end
