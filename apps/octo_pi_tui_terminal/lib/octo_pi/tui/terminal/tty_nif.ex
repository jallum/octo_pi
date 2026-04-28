defmodule OctoPi.TUI.Terminal.TtyNif do
  @moduledoc false

  # NIF wrapper for clearing/restoring IEXTEN on stdin.
  # See c_src/tty_nif.c for context.

  @on_load :load_nif

  @doc false
  def load_nif do
    path = :filename.join(:code.priv_dir(:octo_pi_tui_terminal), ~c"tty_nif")

    case :erlang.load_nif(path, 0) do
      :ok ->
        :ok

      # Already loaded in this VM (e.g. recompile in iex).
      {:error, {:reload, _}} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning("TtyNif: NIF load failed: #{inspect(reason)}")
        :ok
    end
  end

  @doc "Clear IEXTEN on stdin so ctrl+o (VDISCARD) reaches the app."
  @spec clear_iexten() :: :ok | {:error, String.t()}
  def clear_iexten, do: {:error, "NIF not loaded"}

  @doc "Restore IEXTEN on stdin."
  @spec restore_iexten() :: :ok | {:error, String.t()}
  def restore_iexten, do: {:error, "NIF not loaded"}
end
