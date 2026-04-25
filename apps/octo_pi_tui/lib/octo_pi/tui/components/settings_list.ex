defmodule OctoPi.TUI.Components.SettingsList do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  defmodule Item do
    @moduledoc false

    @type item_type :: :radio | :checkbox | :toggle
    @type t :: %__MODULE__{
            id: String.t(),
            label: String.t(),
            type: item_type(),
            options: [term()],
            value: term()
          }

    @enforce_keys [:id, :label, :type, :value]
    defstruct [:id, :label, :type, :value, options: []]

    @spec radio(String.t(), String.t(), [term()], term()) :: t()
    def radio(id, label, options, value) do
      %__MODULE__{id: id, label: label, type: :radio, options: options, value: value}
    end

    @spec checkbox(String.t(), String.t(), boolean()) :: t()
    def checkbox(id, label, checked) do
      %__MODULE__{id: id, label: label, type: :checkbox, options: [], value: checked}
    end

    @spec toggle(String.t(), String.t(), boolean()) :: t()
    def toggle(id, label, on) do
      %__MODULE__{id: id, label: label, type: :toggle, options: [], value: on}
    end
  end

  @type t :: %__MODULE__{
          items: [Item.t()],
          selected: non_neg_integer(),
          theme: Theme.t()
        }

  defstruct [:theme, items: [], selected: 0]

  @spec new([Item.t()], Theme.t()) :: t()
  def new(items, theme) do
    %__MODULE__{items: items, theme: theme}
  end

  @spec update_value(t(), String.t(), term()) :: t()
  def update_value(%__MODULE__{items: items} = s, id, value) do
    items =
      Enum.map(items, fn
        %Item{id: ^id} = item -> %{item | value: value}
        item -> item
      end)

    %{s | items: items}
  end

  @impl true
  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :up}) do
    %{s | selected: wrap(sel - 1, length(items))}
  end

  def handle_key(%__MODULE__{items: items, selected: sel} = s, %Key{key: :down}) do
    %{s | selected: wrap(sel + 1, length(items))}
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :enter}), do: activate(s)
  def handle_key(%__MODULE__{} = s, %Key{key: ?\s}), do: activate(s)
  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}
  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @impl true
  def render(%__MODULE__{items: items, selected: sel, theme: theme}, _width) do
    items
    |> Enum.with_index()
    |> Enum.map(fn {item, idx} ->
      prefix = if idx == sel, do: "→ ", else: "  "
      label = Theme.fg(theme, :text, item.label)
      value_text = Theme.fg(theme, :accent, format_value(item))
      line = "#{prefix}#{label}  #{value_text}"
      if idx == sel, do: "\e[7m#{line}\e[27m", else: line
    end)
  end

  defp activate(%__MODULE__{items: items, selected: sel} = s) do
    item = Enum.at(items, sel)
    {new_value, updated_item} = cycle_item(item)
    updated_items = List.replace_at(items, sel, updated_item)
    {%{s | items: updated_items}, [{:setting_changed, item.id, new_value}]}
  end

  defp cycle_item(%Item{type: :radio, options: opts, value: current} = item) do
    idx = Enum.find_index(opts, &(&1 == current)) || 0
    new_val = Enum.at(opts, rem(idx + 1, length(opts)))
    {new_val, %{item | value: new_val}}
  end

  defp cycle_item(%Item{type: type, value: current} = item) when type in [:checkbox, :toggle] do
    new_val = !current
    {new_val, %{item | value: new_val}}
  end

  defp format_value(%Item{type: :radio, value: v}), do: to_string(v)
  defp format_value(%Item{type: :checkbox, value: true}), do: "☑"
  defp format_value(%Item{type: :checkbox, value: false}), do: "☐"
  defp format_value(%Item{type: :toggle, value: true}), do: "on"
  defp format_value(%Item{type: :toggle, value: false}), do: "off"

  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
