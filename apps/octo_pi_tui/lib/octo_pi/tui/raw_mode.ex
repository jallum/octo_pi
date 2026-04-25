defmodule OctoPi.TUI.RawMode do
  @moduledoc """
  Enter / exit OTP 28's first-class `-noshell` raw submode.

  In raw mode the terminal's line editor is bypassed: keystrokes
  arrive as they happen (no Enter required) and nothing is echoed
  to stdout. See `:shell.start_interactive/1` for the underlying
  mechanism.

  OTP's raw mode clears ICANON but leaves IEXTEN set. IEXTEN causes
  the kernel driver to consume ctrl characters such as ctrl+o
  (VDISCARD) before they reach the application. We clear IEXTEN via
  a thin NIF after entering raw mode and restore it on exit.

  Always bracket `enter/0` with an `exit/0` in an `after` clause
  (or a supervisor `terminate/2`) so the user's terminal is
  restored even when the TUI crashes.
  """

  alias OctoPi.TUI.TtyNif

  require Logger

  @doc "Flip the terminal into raw mode."
  @spec enter() :: :ok | {:error, term()}
  def enter do
    result = :shell.start_interactive({:noshell, :raw})

    case TtyNif.clear_iexten() do
      {:error, msg} -> Logger.warning("RawMode: clear_iexten failed: #{msg}")
      _ -> :ok
    end

    result
  end

  @doc "Restore the terminal to cooked mode."
  @spec exit() :: :ok | {:error, term()}
  def exit do
    case TtyNif.restore_iexten() do
      {:error, msg} -> Logger.warning("RawMode: restore_iexten failed: #{msg}")
      _ -> :ok
    end

    :shell.start_interactive({:noshell, :cooked})
  end
end
