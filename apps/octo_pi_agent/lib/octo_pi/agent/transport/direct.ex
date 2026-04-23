defmodule OctoPi.Agent.Transport.Direct do
  @moduledoc """
  Default transport: call `OctoPi.AI.stream/3` directly.
  """

  @behaviour OctoPi.Agent.Transport

  alias OctoPi.AI

  @impl true
  def stream(model, context, opts), do: AI.stream(model, context, opts)
end
