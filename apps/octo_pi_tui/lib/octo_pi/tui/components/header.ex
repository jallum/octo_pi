defmodule OctoPi.TUI.Components.Header do
  @moduledoc """
  Header banner with logo, version, and keybinding hints.
  Supports compact (single-line hints) and expanded (multi-line) modes.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key

  @type t :: %__MODULE__{expanded: boolean()}

  defstruct expanded: false

  @impl true
  def render(%__MODULE__{expanded: expanded}, _width) do
    logo = "\e[1m\e[36mOctoPi\e[0m" <> dim(" v#{version()}")

    hints =
      if expanded do
        Enum.join(
          [
            hint("Ctrl+C", "to interrupt"),
            hint("Ctrl+L", "to clear"),
            hint("Ctrl+L twice", "to exit"),
            hint("Esc", "to exit (empty)"),
            hint("Ctrl+K", "to delete to end"),
            hint("/", "for commands"),
            hint("!", "to run bash")
          ],
          "\n"
        )
      else
        Enum.join(
          [
            hint("Ctrl+C", "interrupt"),
            hint("Esc", "clear/exit"),
            hint("/", "commands"),
            hint("!", "bash"),
            hint("?", "more")
          ],
          dim(" · ")
        )
      end

    onboarding =
      if expanded do
        dim("OctoPi can explain its own features. Ask it how to use or extend OctoPi.")
      else
        dim("Press ? to show full startup help.")
      end

    lines = String.split("#{logo}\n#{hints}\n#{onboarding}", "\n")
    ["" | lines] ++ [""]
  end

  @impl true
  def handle_key(%__MODULE__{expanded: exp} = s, %Key{key: ??, modifiers: []}) do
    %{s | expanded: not exp}
  end

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  defp hint(key, desc), do: dim(key) <> muted(" #{desc}")

  defp dim(text), do: "\e[2m#{text}\e[22m"
  defp muted(text), do: "\e[38;5;245m#{text}\e[39m"

  defp version do
    case :application.get_key(:octo_pi_tui, :vsn) do
      {:ok, vsn} -> List.to_string(vsn)
      _ -> "0.1.0"
    end
  end
end
