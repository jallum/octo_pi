defmodule OctoPi.TUI.Components.Diff do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @type t :: %__MODULE__{diff_text: String.t()}

  defstruct [:diff_text]

  @impl true
  def render(%__MODULE__{diff_text: diff_text} = self, %RenderContext{theme: theme}),
    do: {self, %VDOM.VLines{lines: render_diff(diff_text, theme)}}

  @spec render_diff(String.t(), Theme.t()) :: [String.t()]
  def render_diff("", _theme), do: []

  def render_diff(diff_text, theme) do
    diff_text
    |> String.split("\n")
    |> render_lines(theme, [])
    |> Enum.reverse()
  end

  @impl true
  def invalidate(state), do: state

  defp render_lines([], _theme, acc), do: acc

  defp render_lines([line | rest], theme, acc) do
    case parse_diff_line(line) do
      {:removed, line_num, content} ->
        {removed, added, rest} = collect_change([{line_num, content}], [], rest)
        new_lines = render_change(removed, added, theme)
        render_lines(rest, theme, Enum.reverse(new_lines, acc))

      {:added, line_num, content} ->
        rendered = Theme.fg(theme, :tool_diff_added, "+#{line_num} #{replace_tabs(content)}")
        render_lines(rest, theme, [rendered | acc])

      {:context, line_num, content} ->
        rendered = Theme.fg(theme, :tool_diff_context, " #{line_num} #{replace_tabs(content)}")
        render_lines(rest, theme, [rendered | acc])

      nil ->
        rendered = Theme.fg(theme, :tool_diff_context, line)
        render_lines(rest, theme, [rendered | acc])
    end
  end

  defp collect_change(removed, added, [line | rest]) do
    case parse_diff_line(line) do
      {:removed, ln, c} -> collect_change(removed ++ [{ln, c}], added, rest)
      {:added, ln, c} -> collect_added(removed, added ++ [{ln, c}], rest)
      _ -> {removed, added, [line | rest]}
    end
  end

  defp collect_change(removed, added, []), do: {removed, added, []}

  defp collect_added(removed, added, [line | rest]) do
    case parse_diff_line(line) do
      {:added, ln, c} -> collect_added(removed, added ++ [{ln, c}], rest)
      _ -> {removed, added, [line | rest]}
    end
  end

  defp collect_added(removed, added, []), do: {removed, added, []}

  defp render_change([{rln, rc}], [{aln, ac}], theme) do
    {removed_content, added_content} = intra_line_diff(replace_tabs(rc), replace_tabs(ac))

    [
      Theme.fg(theme, :tool_diff_removed, "-#{rln} #{removed_content}"),
      Theme.fg(theme, :tool_diff_added, "+#{aln} #{added_content}")
    ]
  end

  defp render_change(removed, added, theme) do
    r =
      Enum.map(removed, fn {ln, c} ->
        Theme.fg(theme, :tool_diff_removed, "-#{ln} #{replace_tabs(c)}")
      end)

    a =
      Enum.map(added, fn {ln, c} ->
        Theme.fg(theme, :tool_diff_added, "+#{ln} #{replace_tabs(c)}")
      end)

    r ++ a
  end

  defp parse_diff_line(line) do
    case Regex.run(~r/^([+\-\s])(\s*\d*)\s(.*)$/, line) do
      [_, "-", line_num, content] -> {:removed, line_num, content}
      [_, "+", line_num, content] -> {:added, line_num, content}
      [_, " ", line_num, content] -> {:context, line_num, content}
      _ -> nil
    end
  end

  defp replace_tabs(text), do: String.replace(text, "\t", "   ")

  defp intra_line_diff(old, new) do
    old_words = split_words(old)
    new_words = split_words(new)
    lcs = lcs_words(old_words, new_words)
    {highlight_removed(old_words, lcs), highlight_added(new_words, lcs)}
  end

  defp split_words(text) do
    ~r/\S+|\s+/ |> Regex.scan(text) |> List.flatten()
  end

  defp lcs_words([], _), do: []
  defp lcs_words(_, []), do: []

  defp lcs_words([h | t1], [h | t2]), do: [h | lcs_words(t1, t2)]

  defp lcs_words([_ | t1] = l1, [_ | t2] = l2) do
    a = lcs_words(t1, l2)
    b = lcs_words(l1, t2)
    if length(a) >= length(b), do: a, else: b
  end

  defp highlight_removed(words, lcs), do: highlight_diff(words, lcs)
  defp highlight_added(words, lcs), do: highlight_diff(words, lcs)

  defp highlight_diff(words, lcs) do
    {result, _remaining_lcs} =
      Enum.reduce(words, {"", lcs}, fn word, {acc, remaining} ->
        case remaining do
          [^word | rest] -> {acc <> word, rest}
          _ -> {acc <> "\e[7m#{word}\e[27m", remaining}
        end
      end)

    result
  end
end
