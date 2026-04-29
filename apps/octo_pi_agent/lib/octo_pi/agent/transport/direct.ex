defmodule OctoPi.Agent.Transport.Direct do
  @moduledoc """
  Default transport: delegates to `OctoPi.AI.stream_to/4` directly.
  """

  @behaviour OctoPi.Agent.Transport

  alias OctoPi.AI

  @impl true
  def stream_to(model, context, opts, pid), do: AI.stream_to(model, context, opts, pid)
end
