defmodule OctoPi.TUI.Components.WelcomeBanner do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.{Key, Theme}

  @type t :: %__MODULE__{
          theme: Theme.t(),
          model: String.t(),
          expanded: boolean(),
          quiet: boolean()
        }

  defstruct [:theme, model: "", expanded: false, quiet: false]

  @spec new(Theme.t(), keyword()) :: t()
  def new(theme, opts \\ []) do
    %__MODULE__{
      theme: theme,
      model: Keyword.get(opts, :model, ""),
      expanded: Keyword.get(opts, :expanded, false),
      quiet: Keyword.get(opts, :quiet, false)
    }
  end

  @impl true
  def render(%__MODULE__{quiet: true}, _width), do: []

  def render(%__MODULE__{expanded: false, model: model, theme: theme}, _width) do
    title = Theme.fg(theme, :accent, "Claude Code")
    hints = dim(" escape interrupt · ctrl+c exit · / commands · ? tips")

    [
      " #{title}  #{dim(model)}",
      hints
    ]
  end

  def render(%__MODULE__{expanded: true, model: model, theme: theme}, _width) do
    title = Theme.fg(theme, :accent, "Claude Code")

    [
      " #{title}  #{dim(model)}",
      "",
      dim("  Esc        interrupt generation"),
      dim("  Shift+Tab  switch input modes"),
      dim("  /help      show available commands"),
      dim("  ?          toggle this banner")
    ]
  end

  @impl true
  def handle_key(%__MODULE__{expanded: expanded} = banner, %Key{key: ??}) do
    %{banner | expanded: !expanded}
  end

  def handle_key(%__MODULE__{} = banner, %Key{}), do: banner

  defp dim(text), do: "\e[2m#{text}\e[22m"
end
