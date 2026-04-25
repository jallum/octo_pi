defmodule OctoPi.TUI.Components.SessionSelector do
  @moduledoc false

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @type t :: %__MODULE__{
          sessions: [map()],
          filtered_sessions: [map()],
          selected: non_neg_integer(),
          current_id: String.t() | nil,
          theme: Theme.t(),
          filter_text: String.t()
        }

  defstruct [
    :theme,
    sessions: [],
    filtered_sessions: [],
    selected: 0,
    current_id: nil,
    filter_text: ""
  ]

  @spec new([map()], Theme.t(), keyword()) :: t()
  def new(sessions, theme, opts \\ []) do
    %__MODULE__{
      sessions: sessions,
      filtered_sessions: sessions,
      theme: theme,
      current_id: Keyword.get(opts, :current)
    }
  end

  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{sessions: sessions} = s, text) do
    downcased = String.downcase(text)

    filtered =
      if downcased == "" do
        sessions
      else
        Enum.filter(sessions, fn sess ->
          name = String.downcase(to_string(Map.get(sess, :name, "")))
          String.contains?(name, downcased)
        end)
      end

    %{s | filtered_sessions: filtered, filter_text: text, selected: 0}
  end

  @impl true
  def handle_key(%__MODULE__{filtered_sessions: sessions, selected: sel} = s, %Key{key: :up}) do
    %{s | selected: wrap(sel - 1, length(sessions))}
  end

  def handle_key(%__MODULE__{filtered_sessions: sessions, selected: sel} = s, %Key{key: :down}) do
    %{s | selected: wrap(sel + 1, length(sessions))}
  end

  def handle_key(%__MODULE__{filtered_sessions: sessions, selected: sel} = s, %Key{key: :enter}) do
    case Enum.at(sessions, sel) do
      nil -> {s, [:cancel]}
      session -> {s, [{:resume_session, session}]}
    end
  end

  def handle_key(%__MODULE__{filtered_sessions: sessions, selected: sel} = s, %Key{key: ?d, modifiers: [:ctrl]}) do
    case Enum.at(sessions, sel) do
      nil -> s
      session -> {s, [{:delete_session, session}]}
    end
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  @impl true
  def render(%__MODULE__{filtered_sessions: [], theme: theme}, _width) do
    [Theme.fg(theme, :muted, "(no sessions)")]
  end

  def render(%__MODULE__{} = s, _width) do
    s.filtered_sessions
    |> Enum.with_index()
    |> Enum.map(&render_item(&1, s))
  end

  defp render_item({session, idx}, %{selected: sel, current_id: current_id, theme: theme}) do
    prefix = if idx == sel, do: "→ ", else: "  "
    check = if to_string(session.id) == to_string(current_id), do: " ✓", else: ""
    name = Theme.fg(theme, :accent, to_string(Map.get(session, :name, session.id)))
    count = Theme.fg(theme, :muted, " (#{Map.get(session, :message_count, 0)} msgs)")
    line = "#{prefix}#{name}#{count}#{check}"
    if idx == sel, do: "\e[7m#{line}\e[27m", else: line
  end

  defp wrap(_idx, 0), do: 0
  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
