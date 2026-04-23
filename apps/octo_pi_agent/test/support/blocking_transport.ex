defmodule OctoPi.Agent.TestSupport.BlockingTransport do
  @moduledoc """
  Transport that yields no events and blocks the consumer forever.
  Use to simulate an LLM stream that hangs mid-reduce so a test can
  exercise the abort-during-stream path. The consumer (loop task) is
  released only by being brutally killed.
  """

  @behaviour OctoPi.Agent.Transport

  @impl true
  def stream(_model, _ctx, _opts) do
    Stream.resource(
      fn -> :ok end,
      fn _acc ->
        # Blocks until the consuming task is killed. The receive has
        # no matching clause that will ever arrive under normal
        # operation.
        receive do
          :never_sent -> {:halt, nil}
        end
      end,
      fn _ -> :ok end
    )
  end
end
