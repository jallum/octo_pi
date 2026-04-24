defmodule OctoPi.TUI.Components.ModelSelector do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.{Key, Theme}

  @type t :: %__MODULE__{
          models: [map()],
          filtered_models: [map()],
          selected: non_neg_integer(),
          current_id: String.t() | nil,
          theme: Theme.t(),
          filter_text: String.t()
        }

  defstruct [
    :theme,
    models: [],
    filtered_models: [],
    selected: 0,
    current_id: nil,
    filter_text: ""
  ]

  @spec new([map()], Theme.t(), keyword()) :: t()
  def new(models, theme, opts \\ []) do
    %__MODULE__{
      models: models,
      filtered_models: models,
      theme: theme,
      current_id: Keyword.get(opts, :current)
    }
  end

  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{models: models} = s, text) do
    downcased = String.downcase(text)

    filtered =
      if downcased == "" do
        models
      else
        Enum.filter(models, fn m ->
          id = String.downcase(to_string(m.id))
          provider = String.downcase(to_string(m.provider))
          String.contains?(id, downcased) or String.contains?(provider, downcased)
        end)
      end

    %{s | filtered_models: filtered, filter_text: text, selected: 0}
  end

  @impl true
  def handle_key(%__MODULE__{filtered_models: models, selected: sel} = s, %Key{key: :up}) do
    len = length(models)
    %{s | selected: wrap(sel - 1, len)}
  end

  def handle_key(%__MODULE__{filtered_models: models, selected: sel} = s, %Key{key: :down}) do
    len = length(models)
    %{s | selected: wrap(sel + 1, len)}
  end

  def handle_key(%__MODULE__{filtered_models: models, selected: sel} = s, %Key{key: :enter}) do
    case Enum.at(models, sel) do
      nil -> {s, [:cancel]}
      model -> {s, [{:select_model, model}]}
    end
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @impl true
  def render(%__MODULE__{filtered_models: [], theme: theme}, _width) do
    [Theme.fg(theme, :muted, "(no models match)")]
  end

  def render(%__MODULE__{} = s, width) do
    s.filtered_models
    |> Enum.with_index()
    |> Enum.map(&render_item(&1, s, width))
  end

  defp render_item({model, idx}, %{selected: sel, current_id: current_id, theme: theme}, _width) do
    prefix = if idx == sel, do: "→ ", else: "  "
    check = if to_string(model.id) == to_string(current_id), do: " ✓", else: ""
    provider_tag = Theme.fg(theme, :muted, " [#{model.provider}]")
    id_text = Theme.fg(theme, :accent, to_string(model.id))
    line = "#{prefix}#{id_text}#{provider_tag}#{check}"
    if idx == sel, do: "\e[7m#{line}\e[27m", else: line
  end

  defp wrap(idx, len) when len == 0, do: idx
  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
