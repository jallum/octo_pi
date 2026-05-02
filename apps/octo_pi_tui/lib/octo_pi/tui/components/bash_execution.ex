defmodule OctoPi.TUI.Components.BashExecution do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @preview_lines 20

  @type status :: :running | :complete | :cancelled | :error
  @type t :: %__MODULE__{
          id: reference() | nil,
          command: String.t(),
          output_lines: [String.t()],
          status: status(),
          exit_code: non_neg_integer() | nil,
          expanded: boolean(),
          excluded: boolean()
        }

  defstruct [
    :id,
    :command,
    output_lines: [],
    status: :running,
    exit_code: nil,
    expanded: false,
    excluded: false
  ]

  @spec new(String.t(), keyword()) :: t()
  def new(command, opts \\ []) do
    %__MODULE__{
      id: Keyword.get(opts, :id),
      command: command,
      excluded: Keyword.get(opts, :excluded, false)
    }
  end

  @spec append_output(t(), String.t()) :: t()
  def append_output(%__MODULE__{output_lines: lines} = be, chunk) do
    clean = chunk |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")
    new_lines = String.split(clean, "\n")

    merged =
      case {lines, new_lines} do
        {[], nl} -> nl
        {[_ | _], [first | rest]} -> List.update_at(lines, -1, &(&1 <> first)) ++ rest
      end

    %{be | output_lines: merged}
  end

  @spec set_complete(t(), non_neg_integer() | nil, keyword()) :: t()
  def set_complete(%__MODULE__{} = be, exit_code, opts \\ []) do
    cancelled = Keyword.get(opts, :cancelled, false)

    status =
      cond do
        cancelled -> :cancelled
        exit_code != nil and exit_code != 0 -> :error
        true -> :complete
      end

    %{be | exit_code: exit_code, status: status}
  end

  @spec set_expanded(t(), boolean()) :: t()
  def set_expanded(%__MODULE__{} = be, expanded), do: %{be | expanded: expanded}

  @spec toggle_expanded(t()) :: t()
  def toggle_expanded(%__MODULE__{expanded: expanded} = be), do: %{be | expanded: !expanded}

  @spec get_output(t()) :: String.t()
  def get_output(%__MODULE__{output_lines: lines}), do: Enum.join(lines, "\n")

  @impl true
  def render(%__MODULE__{} = be, %{theme: theme, width: width}) do
    color_key = if be.excluded, do: :dim, else: :bash_mode
    bg_key = status_bg_key(be.status)
    bg_fn = fn text -> Theme.bg(theme, bg_key, text) end

    header = %Text{content: Theme.fg(theme, color_key, Theme.bold("$ #{be.command}"))}
    content = build_content(be, theme, color_key)

    box =
      Box.new(
        padding_x: 1,
        padding_y: 1,
        bg_fn: bg_fn
      )

    box = Enum.reduce([header | content], box, &Box.add_child(&2, &1))
    {be, %VDOM.VLines{lines: ["" | Box.render(box, width)]}, nil}
  end

  defp build_content(be, theme, color_key) do
    output_children = build_output(be, theme)
    status_children = build_status(be, theme, color_key)
    output_children ++ status_children
  end

  defp build_output(%{output_lines: []}, _theme), do: []

  defp build_output(%{output_lines: lines, expanded: true}, theme) do
    text = Enum.map_join(lines, "\n", &Theme.fg(theme, :muted, &1))
    [%Text{content: text}]
  end

  defp build_output(%{output_lines: lines}, theme) do
    preview = Enum.slice(lines, -@preview_lines, @preview_lines)
    text = Enum.map_join(preview, "\n", &Theme.fg(theme, :muted, &1))
    [%Text{content: text}]
  end

  defp build_status(%{status: :running}, _theme, _color_key) do
    [%Text{content: "Running..."}]
  end

  defp build_status(be, theme, _color_key) do
    parts = []
    parts = maybe_add_hidden_count(parts, be)
    parts = maybe_add_exit_status(parts, be, theme)
    if parts == [], do: [], else: [%Text{content: Enum.join(parts, "\n")}]
  end

  defp maybe_add_hidden_count(parts, %{output_lines: lines}) do
    hidden = length(lines) - @preview_lines

    if hidden > 0 do
      parts ++ ["... #{hidden} more lines"]
    else
      parts
    end
  end

  defp maybe_add_exit_status(parts, %{status: :cancelled}, theme),
    do: parts ++ [Theme.fg(theme, :warning, "(cancelled)")]

  defp maybe_add_exit_status(parts, %{status: :error, exit_code: code}, theme),
    do: parts ++ [Theme.fg(theme, :error, "(exit #{code})")]

  defp maybe_add_exit_status(parts, _, _theme), do: parts

  defp status_bg_key(:running), do: :tool_pending_bg
  defp status_bg_key(:complete), do: :tool_success_bg
  defp status_bg_key(:cancelled), do: :tool_error_bg
  defp status_bg_key(:error), do: :tool_error_bg
end
