defmodule OctoPi.TUI.Components.Header do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{
          theme: Theme.t(),
          model: String.t(),
          expanded: boolean(),
          quiet: boolean(),
          keybindings: Keybindings.t() | nil
        }

  defstruct [:theme, :keybindings, model: "", expanded: false, quiet: false]

  @spec new(Theme.t(), keyword()) :: t()
  def new(theme, opts \\ []) do
    %__MODULE__{
      theme: theme,
      model: Keyword.get(opts, :model, ""),
      expanded: Keyword.get(opts, :expanded, false),
      quiet: Keyword.get(opts, :quiet, false),
      keybindings: Keyword.get(opts, :keybindings)
    }
  end

  @impl true
  def render(%__MODULE__{quiet: true} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}}

  def render(%__MODULE__{expanded: false, theme: theme} = self, %RenderContext{}) do
    title = Theme.fg(theme, :accent, "octo_pi") <> " " <> Theme.dim(version())
    kb = self.keybindings || Keybindings.new()
    separator = Theme.fg(theme, :muted, " · ")

    hints =
      [
        hint(theme, kb, "app.interrupt", "interrupt"),
        raw_hint(theme, "#{key_text(kb, "app.clear")}/#{key_text(kb, "app.exit")}", "clear/exit"),
        raw_hint(theme, "/", "commands"),
        raw_hint(theme, "!", "bash"),
        hint(theme, kb, "app.tools.expand", "more")
      ]
      |> Enum.join(separator)

    help_hint = Theme.dim(" Press #{key_text(kb, "app.tools.expand")} to show full startup help and loaded resources.")
    pi_hint = Theme.dim(" Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.")
    {self, %VDOM.VLines{lines: [" #{title}", " #{hints}", "", help_hint, pi_hint, ""]}}
  end

  def render(%__MODULE__{expanded: true, theme: theme} = self, %RenderContext{}) do
    title = Theme.fg(theme, :accent, "octo_pi") <> " " <> Theme.dim(version())
    kb = self.keybindings || Keybindings.new()

    hints =
      [
        hint(theme, kb, "app.interrupt", "to interrupt"),
        hint(theme, kb, "app.clear", "to clear"),
        raw_hint(theme, "#{key_text(kb, "app.clear")} twice", "to exit"),
        hint(theme, kb, "app.exit", "to exit (empty)"),
        hint(theme, kb, "app.suspend", "to suspend"),
        hint(theme, kb, "tui.editor.deleteToLineEnd", "to delete to end"),
        hint(theme, kb, "app.thinking.cycle", "to cycle thinking level"),
        raw_hint(theme, "#{key_text(kb, "app.model.cycleForward")}/#{key_text(kb, "app.model.cycleBackward")}", "to cycle models"),
        hint(theme, kb, "app.model.select", "to select model"),
        hint(theme, kb, "app.tools.expand", "to expand tools"),
        hint(theme, kb, "app.thinking.toggle", "to expand thinking"),
        hint(theme, kb, "app.editor.external", "for external editor"),
        raw_hint(theme, "/", "for commands"),
        raw_hint(theme, "!", "to run bash"),
        raw_hint(theme, "!!", "to run bash (no context)"),
        hint(theme, kb, "app.message.followUp", "to queue follow-up"),
        hint(theme, kb, "app.message.dequeue", "to edit all queued messages"),
        hint(theme, kb, "app.clipboard.pasteImage", "to paste image"),
        raw_hint(theme, "drop files", "to attach")
      ]
      |> Enum.map(&"  #{&1}")

    pi_hint = Theme.dim(" Pi can explain its own features and look up its docs. Ask it how to use or extend Pi.")
    lines = [" #{title}", ""] ++ hints ++ ["", pi_hint, ""]

    {self, %VDOM.VLines{lines: lines}}
  end

  @impl true
  def handle_key(%__MODULE__{} = header, %Key{}), do: header

  # --- helpers ---

  defp key_text(keybindings, action) do
    case Keybindings.get_keys(keybindings, action) do
      [] -> action
      keys -> Enum.join(keys, "/")
    end
  end

  defp hint(theme, kb, action, description) do
    Theme.dim(key_text(kb, action)) <> Theme.fg(theme, :muted, " #{description}")
  end

  defp raw_hint(theme, key, description) do
    Theme.dim(key) <> Theme.fg(theme, :muted, " #{description}")
  end

  defp version do
    case :application.get_key(:octo_pi_tui, :vsn) do
      {:ok, vsn} -> "v#{vsn}"
      _ -> "dev"
    end
  end
end
