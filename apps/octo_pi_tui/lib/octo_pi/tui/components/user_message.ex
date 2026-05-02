defmodule OctoPi.TUI.Components.UserMessage do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{text: String.t()}

  defstruct [:text]

  @spec new(String.t()) :: t()
  def new(text), do: %__MODULE__{text: text}

  @impl true
  def render(%__MODULE__{} = self, %RenderContext{} = ctx), do: {self, build_vnode(self, ctx), nil}

  defp build_vnode(%__MODULE__{text: t}, _ctx) when t in ["", nil], do: %VDOM.VFlow{children: []}

  defp build_vnode(%__MODULE__{text: text}, %RenderContext{theme: theme, width: width}) do
    if String.trim(text) == "" do
      %VDOM.VFlow{children: []}
    else
      md = Markdown.new(text, theme, padding_x: 1)
      md_lines = Markdown.render(md, width)
      bg_fn = fn l -> Theme.bg(theme, :user_message_bg, pad_to_width(l, width)) end
      styled = [bg_fn.("") | Enum.map(md_lines, bg_fn)] ++ [bg_fn.("")]
      %VDOM.VZone{type: :prompt, id: "USER", children: [%VDOM.VLines{lines: styled}]}
    end
  end

  defp pad_to_width(line, width) do
    visible_len = visible_length(line)
    if visible_len < width, do: line <> String.duplicate(" ", width - visible_len), else: line
  end

  defp visible_length(str) do
    str
    |> String.replace(~r/\e\[[0-9;]*m/, "")
    |> String.length()
  end
end
