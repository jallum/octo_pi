defmodule OctoPi.TUI.Components.Header do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

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
  def render(%__MODULE__{quiet: true} = self, %RenderContext{}), do: {self, %VDOM.VLines{lines: []}}

  def render(%__MODULE__{expanded: false, theme: theme} = self, %RenderContext{}) do
    title = Theme.fg(theme, :accent, "octo_pi") <> " " <> dim(version())
    hints = dim(" escape interrupt · ctrl+c/ctrl+d clear/exit · / commands · ? more")
    {self, %VDOM.VLines{lines: [" #{title}", hints, ""]}}
  end

  def render(%__MODULE__{expanded: true, theme: theme} = self, %RenderContext{}) do
    title = Theme.fg(theme, :accent, "octo_pi") <> " " <> dim(version())

    lines = [
      " #{title}",
      "",
      dim("  Esc        interrupt generation"),
      dim("  Ctrl+C     clear / Ctrl+D exit"),
      dim("  /          commands"),
      dim("  !          run bash command"),
      dim("  ?          toggle this banner"),
      ""
    ]

    {self, %VDOM.VLines{lines: lines}}
  end

  @impl true
  def handle_key(%__MODULE__{expanded: expanded} = header, %Key{key: ??}) do
    %{header | expanded: !expanded}
  end

  def handle_key(%__MODULE__{} = header, %Key{}), do: header

  defp version do
    case :application.get_key(:octo_pi_tui, :vsn) do
      {:ok, vsn} -> "v#{vsn}"
      _ -> "dev"
    end
  end

  defp dim(text), do: "\e[2m#{text}\e[22m"
end
