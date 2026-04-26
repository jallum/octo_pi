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
  @dialyzer {:no_match, enter: 0}
  def enter do
    result = :shell.start_interactive({:noshell, :raw})

    case TtyNif.clear_iexten() do
      {:error, msg} -> Logger.warning("RawMode: clear_iexten failed: #{msg}")
      _ -> :ok
    end

    result
  end

  @doc """
  Restore the terminal to cooked mode.

  Discards any pending stdin bytes via `tcflush(TCIFLUSH)` *before*
  flipping the kernel back to cooked. Without this, terminal-emitted
  bytes that landed in the kernel TTY buffer during shutdown — most
  visibly kitty key-release events for whatever key triggered the
  exit — would be read by the parent shell's readline.
  """
  @spec exit() :: :ok | {:error, term()}
  @dialyzer {:no_match, exit: 0}
  def exit do
    case TtyNif.restore_iexten() do
      {:error, msg} -> Logger.warning("RawMode: restore_iexten failed: #{msg}")
      _ -> :ok
    end

    case TtyNif.flush_input() do
      {:error, msg} -> Logger.warning("RawMode: flush_input failed: #{msg}")
      _ -> :ok
    end

    :shell.start_interactive({:noshell, :cooked})
  end
end
