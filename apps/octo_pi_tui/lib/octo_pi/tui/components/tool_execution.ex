defmodule OctoPi.TUI.Components.ToolExecution do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Theme

  @type status :: :pending | :success | :error
  @type t :: %__MODULE__{
          tool_name: String.t(),
          tool_call_id: String.t(),
          args: map(),
          theme: Theme.t(),
          result: String.t() | nil,
          partial: String.t() | nil,
          status: status(),
          expanded: boolean()
        }

  defstruct [
    :tool_name,
    :tool_call_id,
    :theme,
    args: %{},
    result: nil,
    partial: nil,
    status: :pending,
    expanded: false
  ]

  @spec new(String.t(), String.t(), map(), Theme.t()) :: t()
  def new(tool_name, tool_call_id, args, theme) do
    %__MODULE__{
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      args: args,
      theme: theme
    }
  end

  @spec set_result(t(), String.t(), boolean()) :: t()
  def set_result(%__MODULE__{} = te, result_text, is_error) do
    status = if is_error, do: :error, else: :success
    %{te | result: result_text, status: status, partial: nil}
  end

  @spec update_partial(t(), String.t()) :: t()
  def update_partial(%__MODULE__{} = te, text) do
    %{te | partial: text}
  end

  @spec set_expanded(t(), boolean()) :: t()
  def set_expanded(%__MODULE__{} = te, expanded) do
    %{te | expanded: expanded}
  end

  @spec toggle_expanded(t()) :: t()
  def toggle_expanded(%__MODULE__{expanded: expanded} = te) do
    %{te | expanded: !expanded}
  end

  @impl true
  def render(%__MODULE__{} = te, width) do
    bg_key = status_bg_key(te.status)
    bg_fn = fn text -> Theme.bg(te.theme, bg_key, text) end
    border_color = status_border_color(te)

    header_text = format_header(te)
    content = build_content(te)

    box =
      Box.new(
        border: true,
        title: header_text,
        padding_x: 1,
        bg_fn: bg_fn,
        border_color: border_color
      )

    box = Enum.reduce(content, box, &Box.add_child(&2, &1))
    ["" | Box.render(box, width)]
  end

  defp format_header(te) do
    summary = args_summary(te.args)

    case {summary, te.status} do
      {"", :pending} -> "⏳ #{te.tool_name}"
      {s, :pending} -> "⏳ #{te.tool_name}: #{s}"
      {"", :success} -> "✓ #{te.tool_name}"
      {s, :success} -> "✓ #{te.tool_name}: #{s}"
      {"", :error} -> "✗ #{te.tool_name}"
      {s, :error} -> "✗ #{te.tool_name}: #{s}"
    end
  end

  defp args_summary(args) when map_size(args) == 0, do: ""

  defp args_summary(args) do
    args
    |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{truncate_value(v)}" end)
    |> String.slice(0, 60)
  end

  defp truncate_value(v) when is_binary(v) and byte_size(v) > 40 do
    String.slice(v, 0, 37) <> "..."
  end

  defp truncate_value(v) when is_binary(v), do: v
  defp truncate_value(v), do: inspect(v, limit: 3)

  defp build_content(te) do
    cond do
      te.status == :error and te.result ->
        [%Text{content: Theme.fg(te.theme, :error, te.result)}]

      te.expanded and te.result ->
        [%Text{content: Theme.fg(te.theme, :tool_output, te.result)}]

      te.expanded and te.partial ->
        [%Text{content: Theme.fg(te.theme, :tool_output, te.partial)}]

      te.partial ->
        [%Text{content: Theme.fg(te.theme, :tool_output, String.slice(te.partial, -1, 1))}]

      true ->
        [%Text{content: ""}]
    end
  end

  defp status_bg_key(:pending), do: :tool_pending_bg
  defp status_bg_key(:success), do: :tool_success_bg
  defp status_bg_key(:error), do: :tool_error_bg

  defp status_border_color(%{status: :error, theme: theme}) do
    fn text -> Theme.fg(theme, :error, text) end
  end

  defp status_border_color(%{theme: theme}) do
    fn text -> Theme.fg(theme, :border, text) end
  end
end
