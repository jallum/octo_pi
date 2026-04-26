defmodule OctoPi.TUI.Terminal.SigwinchHandler do
  @moduledoc false
  @behaviour :gen_event

  @impl true
  def init(pid), do: {:ok, pid}

  @impl true
  def handle_event(:sigwinch, pid) do
    send(pid, {:signal, :sigwinch})
    {:ok, pid}
  end

  def handle_event(_, pid), do: {:ok, pid}

  @impl true
  def handle_call(_, pid), do: {:ok, :ok, pid}

  @impl true
  def handle_info(_, pid), do: {:ok, pid}
end
