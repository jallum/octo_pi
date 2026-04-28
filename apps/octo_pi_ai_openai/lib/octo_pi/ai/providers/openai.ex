defmodule OctoPi.AI.Providers.OpenAI do
  @moduledoc """
  OpenAI Completions provider. Implements `OctoPi.AI.Provider` by
  spawning an `OctoPi.AI.Providers.OpenAI.Producer` per call.

  Covers OpenAI proper and any provider speaking the same chat
  completions dialect (xAI, DeepSeek, OpenRouter, etc.) — the
  `Compat` layer handles per-provider quirks.
  """

  @behaviour OctoPi.AI.Provider

  alias OctoPi.AI.Providers.OpenAI.Producer

  @impl true
  def stream_to(model, context, opts, pid, ref) do
    Producer.start(%{
      model: model,
      context: context,
      opts: opts,
      caller: pid,
      ref: ref,
      req_overrides: Application.get_env(:octo_pi_ai, :req_overrides, [])
    })
  end
end
