defmodule OctoPi.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI Completions provider. Implements `OctoPi.AI.Api` by
  spawning an `OctoPi.AI.Providers.OpenAI.Producer` per call.

  Covers OpenAI proper and any provider speaking the same chat
  completions dialect (xAI, DeepSeek, OpenRouter, etc.) — the
  `Compat` layer handles per-provider quirks.
  """

  @behaviour OctoPi.AI.Api

  alias OctoPi.AI.Providers.OpenAI.Producer

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
