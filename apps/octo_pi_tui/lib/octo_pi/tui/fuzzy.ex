defmodule OctoPi.TUI.Fuzzy do
  @moduledoc false

  @type match_result :: %{matches: boolean(), score: float()}

  @word_boundary MapSet.new(~c[ \-_./:\t])

  @spec match(String.t(), String.t()) :: match_result()
  def match(query, text) do
    query_lower = String.downcase(query)
    text_lower = String.downcase(text)

    case match_query(query_lower, text_lower) do
      %{matches: true} = result ->
        result

      primary ->
        try_swapped(query_lower, text_lower, primary)
    end
  end

  @spec filter([item], String.t(), (item -> String.t())) :: [item] when item: var
  def filter(items, query, get_text) do
    trimmed = String.trim(query)

    if trimmed == "" do
      items
    else
      tokens = String.split(trimmed, ~r/\s+/, trim: true)
      do_filter(items, tokens, get_text)
    end
  end

  defp do_filter(items, tokens, get_text) do
    items
    |> Enum.reduce([], fn item, acc ->
      text = get_text.(item)

      case score_all_tokens(tokens, text) do
        {:ok, total} -> [{item, total} | acc]
        :no_match -> acc
      end
    end)
    |> Enum.sort_by(&elem(&1, 1))
    |> Enum.map(&elem(&1, 0))
  end

  defp score_all_tokens(tokens, text) do
    Enum.reduce_while(tokens, {:ok, 0.0}, fn token, {:ok, total} ->
      case match(token, text) do
        %{matches: true, score: s} -> {:cont, {:ok, total + s}}
        _ -> {:halt, :no_match}
      end
    end)
  end

  defp match_query("", _text), do: %{matches: true, score: 0.0}

  defp match_query(query, text) do
    q_chars = String.to_charlist(query)
    t_chars = String.to_charlist(text)

    if length(q_chars) > length(t_chars) do
      %{matches: false, score: 0.0}
    else
      walk(q_chars, t_chars, 0, nil, -1, 0, 0.0)
    end
  end

  defp walk([], _text, _i, _prev, _last, _consec, score) do
    %{matches: true, score: score}
  end

  defp walk(_q, [], _i, _prev, _last, _consec, _score) do
    %{matches: false, score: 0.0}
  end

  defp walk([qh | qt], [th | tt], i, prev, last, consec, score) when qh == th do
    word_boundary? = prev == nil or MapSet.member?(@word_boundary, prev)

    {new_consec, delta} =
      if last == i - 1 do
        c = consec + 1
        {c, -c * 5.0}
      else
        gap = if last >= 0, do: (i - last - 1) * 2.0, else: 0.0
        {0, gap}
      end

    boundary_bonus = if word_boundary?, do: -10.0, else: 0.0
    new_score = score + delta + boundary_bonus + i * 0.1

    walk(qt, tt, i + 1, th, i, new_consec, new_score)
  end

  defp walk(q, [th | tt], i, _prev, last, consec, score) do
    walk(q, tt, i + 1, th, last, consec, score)
  end

  defp try_swapped(query_lower, text_lower, primary) do
    case swap_digits_alpha(query_lower) do
      nil ->
        primary

      swapped ->
        case match_query(swapped, text_lower) do
          %{matches: true, score: s} -> %{matches: true, score: s + 5.0}
          _ -> primary
        end
    end
  end

  defp swap_digits_alpha(q) do
    cond do
      Regex.match?(~r/^[a-z]+[0-9]+$/, q) ->
        [digits, letters] =
          Regex.run(~r/^(?<letters>[a-z]+)(?<digits>[0-9]+)$/, q, capture: :all_names)

        digits <> letters

      Regex.match?(~r/^[0-9]+[a-z]+$/, q) ->
        [digits, letters] =
          Regex.run(~r/^(?<digits>[0-9]+)(?<letters>[a-z]+)$/, q, capture: :all_names)

        letters <> digits

      true ->
        nil
    end
  end
end
