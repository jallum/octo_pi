defmodule OctoPi.TUI.Components.UserMessageSelector do
  @moduledoc false

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @max_visible 10

  @type message :: %{id: String.t(), text: String.t()}

  @type t :: %__MODULE__{
          messages: [message()],
          selected: non_neg_integer(),
          theme: Theme.t()
        }

  defstruct [:theme, messages: [], selected: 0]

  @spec new([message()], Theme.t()) :: t()
  def new(messages, theme) do
    selected = max(0, length(messages) - 1)
    %__MODULE__{messages: messages, theme: theme, selected: selected}
  end

  def handle_key(%__MODULE__{messages: msgs, selected: sel} = s, %Key{key: :up}) do
    %{s | selected: wrap(sel - 1, length(msgs))}
  end

  def handle_key(%__MODULE__{messages: msgs, selected: sel} = s, %Key{key: :down}) do
    %{s | selected: wrap(sel + 1, length(msgs))}
  end

  def handle_key(%__MODULE__{messages: msgs, selected: sel} = s, %Key{key: :enter}) do
    case Enum.at(msgs, sel) do
      nil -> {s, [:cancel]}
      msg -> {s, [{:fork_at, msg}]}
    end
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  def render(%__MODULE__{messages: [], theme: theme}, _width) do
    [Theme.fg(theme, :muted, "  No user messages found")]
  end

  def render(%__MODULE__{messages: msgs, selected: sel, theme: theme}, width) do
    total = length(msgs)
    start_idx = max(0, min(sel - div(@max_visible, 2), total - @max_visible))
    end_idx = min(start_idx + @max_visible, total)

    for_result =
      for i <- start_idx..(end_idx - 1) do
        msg = Enum.at(msgs, i)
        is_sel = i == sel
        cursor = if is_sel, do: Theme.fg(theme, :accent, "› "), else: "  "
        text = msg.text |> String.replace("\n", " ") |> String.trim()
        max_w = max(0, width - 2)
        text = if String.length(text) > max_w, do: String.slice(text, 0, max_w - 3) <> "...", else: text
        text = if is_sel, do: "\e[1m#{text}\e[0m", else: text
        meta = Theme.fg(theme, :muted, "  Message #{i + 1} of #{total}")
        [cursor <> text, meta, ""]
      end

    lines = List.flatten(for_result)

    scroll_line =
      if start_idx > 0 or end_idx < total,
        do: [Theme.fg(theme, :muted, "  (#{sel + 1}/#{total})")],
        else: []

    lines ++ scroll_line
  end

  @spec invalidate(t()) :: t()
  def invalidate(s), do: s

  defp wrap(_idx, 0), do: 0
  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
