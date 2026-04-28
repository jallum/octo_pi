defmodule OctoPi.Agent.Transport.Direct do
  @moduledoc """
  Default transport: delegates to `OctoPi.AI.stream_to/5` directly.
  """

  @behaviour OctoPi.Agent.Transport

  alias OctoPi.AI

  @impl true
  def stream_to(model, context, opts, pid, ref), do: AI.stream_to(model, context, opts, pid, ref)
end
