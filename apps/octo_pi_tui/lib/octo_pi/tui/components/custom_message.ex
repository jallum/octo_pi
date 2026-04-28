defmodule OctoPi.TUI.Components.CustomMessage do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Theme

  @type renderer :: (t(), keyword(), Theme.t() -> [String.t()])

  @type t :: %__MODULE__{
          custom_type: String.t(),
          content: String.t(),
          theme: Theme.t(),
          renderer: renderer() | nil,
          expanded: boolean()
        }

  defstruct [:custom_type, :content, :theme, :renderer, expanded: false]

  @spec new(String.t(), String.t(), Theme.t(), keyword()) :: t()
  def new(custom_type, content, theme, opts \\ []) do
    %__MODULE__{
      custom_type: custom_type,
      content: content,
      theme: theme,
      renderer: Keyword.get(opts, :renderer)
    }
  end

  @spec toggle_expanded(t()) :: t()
  def toggle_expanded(%__MODULE__{expanded: e} = msg), do: %{msg | expanded: !e}

  @impl true
  def render(%__MODULE__{renderer: renderer} = msg, width) when is_function(renderer) do
    try_custom_render(msg, width)
  end

  def render(%__MODULE__{} = msg, width), do: render_default(msg, width)

  @impl true
  def handle_key(%__MODULE__{} = msg, _key), do: msg

  @impl true
  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  defp try_custom_render(msg, width) do
    msg.renderer.(msg, [expanded: msg.expanded], msg.theme)
  rescue
    _ -> render_default(msg, width)
  end

  defp render_default(msg, width) do
    label = Theme.fg(msg.theme, :custom_message_label, Theme.bold("[#{msg.custom_type}]"))

    md = Markdown.new(msg.content, msg.theme, padding_x: 0)
    content_lines = Markdown.render(md, width - 4)

    children =
      [%Text{content: label}, %Text{content: ""}] ++
        Enum.map(content_lines, fn line -> %Text{content: line} end)

    bg_fn = fn text -> Theme.bg(msg.theme, :custom_message_bg, text) end

    box =
      Box.new(
        border: false,
        padding_x: 1,
        bg_fn: bg_fn
      )

    box = Enum.reduce(children, box, &Box.add_child(&2, &1))
    ["" | Box.render(box, width)]
  end
end
