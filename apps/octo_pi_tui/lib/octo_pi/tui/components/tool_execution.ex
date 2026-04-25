defmodule OctoPi.TUI.Components.ToolExecution do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.Coder.Extension.ToolRender
  alias OctoPi.TUI.Components.Box
  alias OctoPi.TUI.Components.Text
  alias OctoPi.TUI.Theme

  @type render_fn :: (ToolRender.Context.t() -> [String.t()])
  @type status :: :pending | :success | :error
  @type t :: %__MODULE__{
          tool_name: String.t(),
          tool_call_id: String.t(),
          args: map(),
          theme: Theme.t(),
          result: String.t() | nil,
          partial: String.t() | nil,
          status: status(),
          expanded: boolean(),
          render_call: render_fn() | nil,
          render_result: render_fn() | nil,
          render_shell: :default | :self
        }

  defstruct [
    :tool_name,
    :tool_call_id,
    :theme,
    :render_call,
    :render_result,
    args: %{},
    result: nil,
    partial: nil,
    status: :pending,
    expanded: false,
    render_shell: :default
  ]

  @spec new(String.t(), String.t(), map(), Theme.t(), keyword()) :: t()
  def new(tool_name, tool_call_id, args, theme, opts \\ []) do
    %__MODULE__{
      tool_name: tool_name,
      tool_call_id: tool_call_id,
      args: args,
      theme: theme,
      render_call: Keyword.get(opts, :render_call),
      render_result: Keyword.get(opts, :render_result),
      render_shell: Keyword.get(opts, :render_shell, :default)
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
    case custom_render_fn(te) do
      nil -> render_default(te, width)
      custom_fn -> render_custom(te, custom_fn, width)
    end
  end

  defp custom_render_fn(%{status: :pending, render_call: f}) when is_function(f), do: f

  defp custom_render_fn(%{status: s, render_result: f}) when s in [:success, :error] and is_function(f), do: f

  defp custom_render_fn(_), do: nil

  defp render_custom(te, custom_fn, width) do
    ctx = build_render_context(te)
    custom_lines = custom_fn.(ctx)

    case te.render_shell do
      :self -> ["" | custom_lines]
      :default -> render_in_box(te, custom_lines, width)
    end
  end

  defp render_default(te, width) do
    content = build_content(te)
    render_in_box(te, content, width)
  end

  defp render_in_box(te, content, width) do
    bg_key = status_bg_key(te.status)
    bg_fn = fn text -> Theme.bg(te.theme, bg_key, text) end
    header_text = format_header(te)
    styled_header = Theme.fg(te.theme, :tool_title, Theme.bold(header_text))

    box =
      Box.new(
        padding_x: 1,
        padding_y: 1,
        bg_fn: bg_fn
      )

    children =
      [%Text{content: styled_header}] ++
        Enum.map(content, fn
          %Text{} = t -> t
          line when is_binary(line) -> %Text{content: line}
        end)

    box = Enum.reduce(children, box, &Box.add_child(&2, &1))
    ["" | Box.render(box, width)]
  end

  defp build_render_context(te) do
    %ToolRender.Context{
      args: te.args,
      tool_call_id: te.tool_call_id,
      execution_started: te.status != :pending,
      args_complete: true,
      is_partial: te.partial != nil,
      expanded: te.expanded,
      is_error: te.status == :error
    }
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

  @preview_lines 5

  defp build_content(%{status: :error, result: result, theme: theme}) when result != nil do
    [%Text{content: Theme.fg(theme, :error, result)}]
  end

  defp build_content(%{expanded: true, result: result, theme: theme}) when result != nil do
    [%Text{content: Theme.fg(theme, :tool_output, result)}]
  end

  defp build_content(%{expanded: true, partial: partial, theme: theme}) when partial != nil do
    [%Text{content: Theme.fg(theme, :tool_output, partial)}]
  end

  defp build_content(%{result: result, theme: theme}) when result != nil do
    preview_collapsed(result, theme)
  end

  defp build_content(%{partial: partial, theme: theme}) when partial != nil do
    [%Text{content: Theme.fg(theme, :tool_output, String.slice(partial, -1, 1))}]
  end

  defp build_content(_te) do
    [%Text{content: ""}]
  end

  defp preview_collapsed(result, theme) do
    lines = String.split(result, "\n")
    total = length(lines)

    if total <= @preview_lines do
      [%Text{content: Theme.fg(theme, :tool_output, result)}]
    else
      preview = lines |> Enum.take(-@preview_lines) |> Enum.join("\n")
      skipped = total - @preview_lines
      hint = Theme.fg(theme, :muted, "... (#{skipped} earlier lines)")

      [
        %Text{content: hint},
        %Text{content: Theme.fg(theme, :tool_output, preview)}
      ]
    end
  end

  defp status_bg_key(:pending), do: :tool_pending_bg
  defp status_bg_key(:success), do: :tool_success_bg
  defp status_bg_key(:error), do: :tool_error_bg
end
