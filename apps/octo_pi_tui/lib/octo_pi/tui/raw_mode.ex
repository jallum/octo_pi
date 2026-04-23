defmodule OctoPi.TUI.RawMode do
  @moduledoc """
  Enter / exit OTP 28's first-class `-noshell` raw submode.

  In raw mode the terminal's line editor is bypassed: keystrokes
  arrive as they happen (no Enter required) and nothing is echoed
  to stdout. See `:shell.start_interactive/1` for the underlying
  mechanism.

  Always bracket `enter/0` with an `exit/0` in an `after` clause
  (or a supervisor `terminate/2`) so the user's terminal is
  restored even when the TUI crashes.
  """

  @doc "Flip the terminal into raw mode."
  @spec enter() :: :ok | {:error, term()}
  def enter, do: :shell.start_interactive({:noshell, :raw})

  @doc "Restore the terminal to cooked mode."
  @spec exit() :: :ok | {:error, term()}
  def exit, do: :shell.start_interactive({:noshell, :cooked})
end
