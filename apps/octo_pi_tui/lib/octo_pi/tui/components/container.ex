defmodule OctoPi.TUI.Components.Container do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  @type t :: %__MODULE__{children: [struct()]}

  defstruct children: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new([struct()]) :: t()
  def new(children) when is_list(children), do: %__MODULE__{children: children}

  @spec add_child(t(), struct()) :: t()
  def add_child(%__MODULE__{children: children} = c, child) do
    %{c | children: children ++ [child]}
  end

  @spec remove_child(t(), non_neg_integer()) :: t()
  def remove_child(%__MODULE__{children: children} = c, index) do
    %{c | children: List.delete_at(children, index)}
  end

  @spec clear(t()) :: t()
  def clear(%__MODULE__{} = c), do: %{c | children: []}

  @spec update_child(t(), non_neg_integer(), struct()) :: t()
  def update_child(%__MODULE__{children: children} = c, index, child) do
    %{c | children: List.replace_at(children, index, child)}
  end

  @spec child_count(t()) :: non_neg_integer()
  def child_count(%__MODULE__{children: children}), do: length(children)

  @impl true
  def render(%__MODULE__{children: children}, width) do
    Enum.flat_map(children, &render_child(&1, width))
  end

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  defp render_child(%mod{} = child, width), do: mod.render(child, width)
end
