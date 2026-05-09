defmodule OctoPi.TUI.Components.SessionSelector do
  @moduledoc false

  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @sort_modes [:modified, :name, :created]

  @type sort_mode :: :modified | :created | :name

  @type t :: %__MODULE__{
          sessions: [map()],
          filtered_sessions: [map()],
          selected: non_neg_integer(),
          current_id: String.t() | nil,
          theme: Theme.t(),
          filter_text: String.t(),
          sort_mode: sort_mode(),
          named_only: boolean(),
          show_path: boolean(),
          confirm_delete: map() | nil
        }

  defstruct [
    :theme,
    sessions: [],
    filtered_sessions: [],
    selected: 0,
    current_id: nil,
    filter_text: "",
    sort_mode: :modified,
    named_only: false,
    show_path: false,
    confirm_delete: nil
  ]

  @spec new([map()], Theme.t(), keyword()) :: t()
  def new(sessions, theme, opts \\ []) do
    s = %__MODULE__{
      sessions: sessions,
      theme: theme,
      current_id: Keyword.get(opts, :current),
      sort_mode: Keyword.get(opts, :sort_mode, :modified)
    }

    apply_filters_and_sort(s)
  end

  @spec filter(t(), String.t()) :: t()
  def filter(%__MODULE__{} = s, text) do
    apply_filters_and_sort(%{s | filter_text: text, selected: 0})
  end

  def handle_key(%__MODULE__{confirm_delete: cd} = s, %Key{key: ?y}) when not is_nil(cd) do
    {%{s | confirm_delete: nil}, [{:delete_session, cd}]}
  end

  def handle_key(%__MODULE__{confirm_delete: cd} = s, %Key{key: ?n}) when not is_nil(cd) do
    %{s | confirm_delete: nil}
  end

  def handle_key(%__MODULE__{confirm_delete: cd} = s, %Key{key: :escape}) when not is_nil(cd) do
    %{s | confirm_delete: nil}
  end

  def handle_key(%__MODULE__{confirm_delete: cd} = s, %Key{}) when not is_nil(cd) do
    s
  end

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
      session -> %{s | confirm_delete: session}
    end
  end

  def handle_key(%__MODULE__{} = s, %Key{key: ?s, modifiers: [:ctrl]}) do
    apply_filters_and_sort(%{s | sort_mode: next_sort_mode(s.sort_mode), selected: 0})
  end

  def handle_key(%__MODULE__{} = s, %Key{key: ?n, modifiers: [:ctrl]}) do
    apply_filters_and_sort(%{s | named_only: not s.named_only, selected: 0})
  end

  def handle_key(%__MODULE__{} = s, %Key{key: ?p, modifiers: [:ctrl]}) do
    %{s | show_path: not s.show_path}
  end

  def handle_key(%__MODULE__{} = s, %Key{key: :escape}), do: {s, [:cancel]}

  def handle_key(%__MODULE__{} = s, %Key{}), do: s

  def render(%__MODULE__{confirm_delete: cd, theme: theme}, _width) when not is_nil(cd) do
    name = Map.get(cd, :name, Map.get(cd, :id, "session"))
    [Theme.fg(theme, :muted, "Delete \"#{name}\"? (y/n)")]
  end

  def render(%__MODULE__{filtered_sessions: [], theme: theme}, _width) do
    [Theme.fg(theme, :muted, "(no sessions)")]
  end

  def render(%__MODULE__{} = s, width) do
    session_lines =
      s.filtered_sessions
      |> Enum.with_index()
      |> Enum.map(&render_item(&1, s, width))

    total = length(s.filtered_sessions)
    badge = Theme.fg(s.theme, :muted, "(#{s.selected + 1}/#{total})")
    status = build_status_line(s)

    session_lines ++ [badge, status]
  end

  @spec invalidate(t()) :: t()
  def invalidate(state), do: state

  # --- private ---

  defp apply_filters_and_sort(%__MODULE__{sessions: sessions} = s) do
    filtered =
      sessions
      |> then(fn ss -> if s.named_only, do: Enum.filter(ss, &named?/1), else: ss end)
      |> then(fn ss ->
        downcased = String.downcase(s.filter_text)
        if downcased == "", do: ss, else: Enum.filter(ss, &matches_text?(&1, downcased))
      end)
      |> sort_sessions(s.sort_mode)

    %{s | filtered_sessions: filtered}
  end

  defp named?(session), do: Map.get(session, :name, "") != Map.get(session, :id, "")

  defp matches_text?(session, downcased) do
    name = session |> Map.get(:name, "") |> to_string() |> String.downcase()
    String.contains?(name, downcased)
  end

  defp sort_sessions(sessions, :modified) do
    Enum.sort_by(sessions, &Map.get(&1, :updated_at, ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp sort_sessions(sessions, :created) do
    Enum.sort_by(sessions, &Map.get(&1, :created_at, ~U[1970-01-01 00:00:00Z]), {:desc, DateTime})
  end

  defp sort_sessions(sessions, :name) do
    Enum.sort_by(sessions, &(&1 |> Map.get(:name, "") |> to_string() |> String.downcase()))
  end

  defp next_sort_mode(current) do
    idx = Enum.find_index(@sort_modes, &(&1 == current)) || 0
    Enum.at(@sort_modes, rem(idx + 1, length(@sort_modes)))
  end

  defp render_item({session, idx}, %{selected: sel, current_id: current_id, theme: theme, show_path: show_path}, width) do
    is_selected = idx == sel
    is_current = to_string(session.id) == to_string(current_id)

    prefix = if is_selected, do: "→ ", else: "  "
    check = if is_current, do: " ✓", else: ""

    label =
      if show_path,
        do: Map.get(session, :path, to_string(Map.get(session, :id, ""))),
        else: to_string(Map.get(session, :name, session.id))

    label = Theme.fg(theme, :accent, label)
    count_str = " (#{Map.get(session, :message_count, 0)} msgs)"
    age_str = format_age(Map.get(session, :updated_at))
    right = Theme.fg(theme, :muted, "#{count_str}  #{age_str}#{check}")

    line = prefix <> label <> right
    line = truncate(line, width)
    if is_selected, do: "\e[7m#{line}\e[27m", else: line
  end

  defp build_status_line(%{sort_mode: sort_mode, named_only: named_only, theme: theme}) do
    sort_label = "sort: #{sort_mode}"
    named_hint = if named_only, do: "  [ctrl+n: named only]", else: ""
    Theme.fg(theme, :muted, "scope: local  #{sort_label}#{named_hint}")
  end

  defp format_age(nil), do: ""

  defp format_age(%DateTime{} = dt) do
    diff_s = DateTime.diff(DateTime.utc_now(), dt)
    diff_m = div(diff_s, 60)
    diff_h = div(diff_m, 60)
    diff_d = div(diff_h, 24)

    cond do
      diff_s < 60 -> "now"
      diff_m < 60 -> "#{diff_m}m"
      diff_h < 24 -> "#{diff_h}h"
      diff_d < 7 -> "#{diff_d}d"
      diff_d < 30 -> "#{div(diff_d, 7)}w"
      diff_d < 365 -> "#{div(diff_d, 30)}mo"
      true -> "#{div(diff_d, 365)}y"
    end
  end

  defp truncate(line, width) when width > 3 do
    visible = line |> String.replace(~r/\e\[[0-9;]*m/, "") |> String.length()
    if visible > width, do: String.slice(line, 0, width - 3) <> "...", else: line
  end

  defp truncate(line, _), do: line

  defp wrap(_idx, 0), do: 0
  defp wrap(idx, len) when idx < 0, do: len - 1
  defp wrap(idx, len) when idx >= len, do: 0
  defp wrap(idx, _len), do: idx
end
