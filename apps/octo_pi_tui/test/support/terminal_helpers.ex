defmodule OctoPi.TUI.TerminalHelpers do
  @moduledoc false

  # Test-only conveniences for driving a `Terminal` GenServer in unit
  # tests. These intentionally live in `test/support` so production
  # code stays free of synthetic-input plumbing.

  @doc "Inject a raw stdin chunk as if it arrived from the reader."
  @spec simulate_stdin(GenServer.server(), binary()) :: :ok
  def simulate_stdin(pid, bin) when is_binary(bin) do
    send(pid, {:stdin_chunk, bin})
    :ok
  end

  @doc "Trigger Terminal's resize broadcast with the given dimensions."
  @spec simulate_resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def simulate_resize(pid, width, height), do: GenServer.call(pid, {:resize, width, height})
end
