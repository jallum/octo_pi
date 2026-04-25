defmodule OctoPi.TUI.Components.AssistantMessage do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.{Theme, WrapAnsi}

  @osc133_zone_start "\e]133;A\a"
  @osc133_zone_end "\e]133;B\a"
  @osc133_zone_final "\e]133;C\a"

  @type content_block :: {:text, String.t()} | {:thinking, String.t()}

  @type t :: %__MODULE__{
          theme: Theme.t(),
          content: [content_block()],
          stop_reason: nil | :aborted | :error,
          error_message: String.t() | nil,
          hide_thinking: boolean(),
          hidden_thinking_label: String.t(),
          has_tool_calls: boolean()
        }

  defstruct [
    :theme,
    content: [],
    stop_reason: nil,
    error_message: nil,
    hide_thinking: false,
    hidden_thinking_label: "Thinking...",
    has_tool_calls: false
  ]

  @spec new(Theme.t(), keyword()) :: t()
  def new(theme, opts \\ []) do
    struct!(__MODULE__, Keyword.put(opts, :theme, theme))
  end

  @spec update_content(t(), keyword()) :: t()
  def update_content(%__MODULE__{} = msg, updates) do
    struct!(msg, updates)
  end

  @impl true
  def render(%__MODULE__{} = msg, width) do
    lines = render_content(msg, width)

    lines =
      if not msg.has_tool_calls and lines != [] do
        wrap_osc133(lines)
      else
        lines
      end

    lines
  end

  defp render_content(%__MODULE__{content: content, theme: theme} = msg, width) do
    visible_content =
      Enum.filter(content, fn
        {:text, text} -> String.trim(text) != ""
        {:thinking, text} -> String.trim(text) != ""
      end)

    has_visible = visible_content != []

    content_lines =
      if has_visible do
        lines = [""]
        lines ++ render_blocks(content, Enum.count(content), theme, msg, width)
      else
        []
      end

    content_lines ++ render_status(msg, has_visible)
  end

  defp render_blocks(content, count, theme, msg, width) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {block, idx} ->
      has_visible_after = has_visible_content_after(content, idx)
      render_block(block, theme, msg, width, has_visible_after, idx < count - 1)
    end)
  end

  defp render_block({:text, text}, theme, _msg, width, _has_after, _more) do
    text = String.trim(text)

    if text == "" do
      []
    else
      md = Markdown.new(text, theme, padding_x: 1)
      Markdown.render(md, width)
    end
  end

  defp render_block({:thinking, text}, theme, msg, width, has_after, _more) do
    text = String.trim(text)

    if text == "" do
      []
    else
      lines = render_thinking(text, theme, msg, width)
      if has_after, do: lines ++ [""], else: lines
    end
  end

  defp render_thinking(_text, theme, %{hide_thinking: true} = msg, _width) do
    label = msg.hidden_thinking_label
    [" " <> Theme.fg(theme, :thinking_text, Theme.italic(label))]
  end

  defp render_thinking(text, theme, _msg, width) do
    content_width = max(1, width - 1)

    text
    |> WrapAnsi.wrap(content_width)
    |> Enum.map(fn line ->
      " " <> Theme.fg(theme, :thinking_text, Theme.italic(line))
    end)
  end

  defp render_status(%{stop_reason: nil}, _has_visible), do: []
  defp render_status(%{has_tool_calls: true}, _has_visible), do: []

  defp render_status(%{stop_reason: :aborted} = msg, _has_visible) do
    text =
      if msg.error_message && msg.error_message != "Request was aborted" do
        msg.error_message
      else
        "Operation aborted"
      end

    ["", Theme.fg(msg.theme, :error, text)]
  end

  defp render_status(%{stop_reason: :error} = msg, _has_visible) do
    text = "Error: #{msg.error_message || "Unknown error"}"
    ["", Theme.fg(msg.theme, :error, text)]
  end

  defp render_status(_msg, _has_visible), do: []

  defp has_visible_content_after(content, idx) do
    content
    |> Enum.drop(idx + 1)
    |> Enum.any?(fn
      {:text, t} -> String.trim(t) != ""
      {:thinking, t} -> String.trim(t) != ""
    end)
  end

  defp wrap_osc133([single]) do
    [@osc133_zone_start <> single <> @osc133_zone_end <> @osc133_zone_final]
  end

  defp wrap_osc133([first | rest]) do
    {middle, [last]} = Enum.split(rest, -1)
    tagged_last = @osc133_zone_end <> @osc133_zone_final <> last
    [@osc133_zone_start <> first | middle] ++ [tagged_last]
  end
end
