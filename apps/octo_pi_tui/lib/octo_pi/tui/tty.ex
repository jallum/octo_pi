defmodule OctoPi.TUI.TTY do
  @moduledoc false
  @on_load :load_nif

  defp load_nif do
    path = :filename.join(:code.priv_dir(:octo_pi_tui), ~c"tty_nif")
    :erlang.load_nif(path, 0)
  end

  @spec window_size() :: {:ok, {pos_integer(), pos_integer()}} | {:error, atom()}
  def window_size, do: :erlang.nif_error(:not_loaded)
end
