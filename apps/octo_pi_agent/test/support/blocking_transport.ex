defmodule OctoPi.Agent.TestSupport.BlockingTransport do
  @moduledoc """
  Transport that yields no events and blocks the consumer forever.
  Use to simulate an LLM stream that hangs so a test can exercise the
  abort-during-stream path. The producer task blocks until killed.
  """

  @behaviour OctoPi.Agent.Transport

  @impl true
  def stream_to(_model, _ctx, _opts, _caller) do
    {:ok,
     spawn(fn ->
       receive do
         :never_sent -> :ok
       end
     end)}
  end
end
