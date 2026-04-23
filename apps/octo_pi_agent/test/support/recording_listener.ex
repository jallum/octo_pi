defmodule OctoPi.Agent.TestSupport.RecordingListener do
  @moduledoc """
  Tiny GenServer that replies to `:sync` subscriber dispatches so
  we can exercise the `Subscribers.dispatch/2` barrier. On each
  event, forwards `{label, event}` to the owner pid before replying.
  """

  use GenServer

  def start_link({owner, label}) do
    GenServer.start_link(__MODULE__, {owner, label})
  end

  @impl true
  def init({owner, label}), do: {:ok, {owner, label}}

  @impl true
  def handle_call({:octo_pi_agent_event, event}, _from, {owner, label} = state) do
    send(owner, {label, event})
    {:reply, :ok, state}
  end
end
