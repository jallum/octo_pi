defmodule OctoPi.TUI.Components.SettingsSelector do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  defmodule Item do
    @moduledoc false
    @enforce_keys [:key, :label, :options, :value]
    defstruct [:key, :label, :options, :value]

    @type t :: %__MODULE__{
            key: atom(),
            label: String.t(),
            options: [atom()],
            value: atom()
          }
  end

  @type t :: %__MODULE__{
          items: [Item.t()],
          selected: non_neg_integer(),
          theme: Theme.t()
        }

  defstruct [:theme, items: [], selected: 0]

  @spec new(Theme.t(), keyword()) :: t()
  def new(theme, opts \\ []) do
    items =
      Enum.map(default_items(), fn item ->
        case Keyword.get(opts, item.key) do
          nil -> item
          val -> %{item | value: val}
        end
      end)

    %__MODULE__{items: items, theme: theme}
  end

  defp default_items do
    [
      %Item{key: :theme, label: "Theme", options: [:dark, :light], value: :dark},
      %Item{
        key: :thinking_level,
        label: "Thinking Level",
        options: [:off, :brief, :verbose],
        value: :brief
      },
      %Item{
        key: :tool_expand,
        label: "Tool Expansion",
        options: [:collapsed, :expanded],
        value: :collapsed
      },
      %Item{key: :hardware_cursor, label: "Hardware Cursor", options: [:on, :off], value: :on}
    ]
  end

  @impl true
  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :up}) do
    %{s | selected: wrap(sel - 1, length(items))}
  end

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :down}) do
    %{s | selected: wrap(sel + 1, length(items))}
  end

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :enter}) do
    item = Enum.at(items, sel)
    next_value = cycle_value(item.options, item.value)
    updated_item = %{item | value: next_value}
    updated_items = List.replace_at(items, sel, updated_item)
    {%{s | items: updated_items}, [{:setting_changed, item.key, next_value}]}
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @impl true
  def render(%__MODULE__{items: items, selected: sel, theme: theme}, _width) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      prefix = if idx == sel, do: "→ ", else: "  "
      label = Theme.fg(theme, :text, item.label)
      value = Theme.fg(theme, :accent, to_string(item.value))
      line = "#{prefix}#{label}: #{value}"
      if idx == sel, do: "\e[7m#{line}\e[27m", else: line
    end)
  end

  defp cycle_value(options, current) do
    idx = Enum.find_index(options, &(&1 == current)) || 0
    Enum.at(options, rem(idx + 1, length(options)))
  end

  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
