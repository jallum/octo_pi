defmodule OctoPi.TUI.WrapAnsi.Tracker do
  @moduledoc false

  defstruct bold: false,
            dim: false,
            italic: false,
            underline: false,
            blink: false,
            inverse: false,
            hidden: false,
            strikethrough: false,
            fg: nil,
            bg: nil,
            hyperlink: nil

  @type t :: %__MODULE__{}

  @spec process(t(), String.t()) :: t()
  def process(%__MODULE__{} = t, <<"\e[", rest::binary>>) do
    if String.ends_with?(rest, "m") do
      params = rest |> String.slice(0..-2//1) |> parse_sgr()
      apply_sgr(t, params)
    else
      t
    end
  end

  def process(%__MODULE__{} = t, <<"\e]8;", _::binary>> = code), do: apply_hyperlink(t, code)

  def process(%__MODULE__{} = t, _), do: t

  @spec active_codes(t()) :: String.t()
  def active_codes(%__MODULE__{} = t) do
    codes =
      []
      |> maybe_add(t.bold, "1")
      |> maybe_add(t.dim, "2")
      |> maybe_add(t.italic, "3")
      |> maybe_add(t.underline, "4")
      |> maybe_add(t.blink, "5")
      |> maybe_add(t.inverse, "7")
      |> maybe_add(t.hidden, "8")
      |> maybe_add(t.strikethrough, "9")
      |> maybe_add(t.fg != nil, t.fg)
      |> maybe_add(t.bg != nil, t.bg)

    sgr =
      case Enum.reverse(codes) do
        [] -> ""
        params -> "\e[#{Enum.join(params, ";")}m"
      end

    link = if t.hyperlink, do: "\e]8;;#{t.hyperlink}\e\\", else: ""
    sgr <> link
  end

  @spec line_end_reset(t()) :: String.t()
  def line_end_reset(%__MODULE__{} = t) do
    ul = if t.underline, do: "\e[24m", else: ""
    hl = if t.hyperlink, do: "\e]8;;\e\\", else: ""
    ul <> hl
  end

  # --- SGR parsing ---

  defp maybe_add(acc, false, _), do: acc
  defp maybe_add(acc, nil, _), do: acc
  defp maybe_add(acc, true, val), do: [val | acc]
  defp maybe_add(acc, _, _), do: acc

  defp parse_sgr(""), do: [0]

  defp parse_sgr(str) do
    str |> String.split(";") |> Enum.map(&parse_int/1)
  end

  defp parse_int(""), do: 0
  defp parse_int(s), do: String.to_integer(s)

  defp apply_sgr(t, []), do: t
  defp apply_sgr(t, [0 | r]), do: apply_sgr(%__MODULE__{hyperlink: t.hyperlink}, r)
  defp apply_sgr(t, [1 | r]), do: apply_sgr(%{t | bold: true}, r)
  defp apply_sgr(t, [2 | r]), do: apply_sgr(%{t | dim: true}, r)
  defp apply_sgr(t, [3 | r]), do: apply_sgr(%{t | italic: true}, r)
  defp apply_sgr(t, [4 | r]), do: apply_sgr(%{t | underline: true}, r)
  defp apply_sgr(t, [5 | r]), do: apply_sgr(%{t | blink: true}, r)
  defp apply_sgr(t, [7 | r]), do: apply_sgr(%{t | inverse: true}, r)
  defp apply_sgr(t, [8 | r]), do: apply_sgr(%{t | hidden: true}, r)
  defp apply_sgr(t, [9 | r]), do: apply_sgr(%{t | strikethrough: true}, r)
  defp apply_sgr(t, [22 | r]), do: apply_sgr(%{t | bold: false, dim: false}, r)
  defp apply_sgr(t, [23 | r]), do: apply_sgr(%{t | italic: false}, r)
  defp apply_sgr(t, [24 | r]), do: apply_sgr(%{t | underline: false}, r)
  defp apply_sgr(t, [25 | r]), do: apply_sgr(%{t | blink: false}, r)
  defp apply_sgr(t, [27 | r]), do: apply_sgr(%{t | inverse: false}, r)
  defp apply_sgr(t, [28 | r]), do: apply_sgr(%{t | hidden: false}, r)
  defp apply_sgr(t, [29 | r]), do: apply_sgr(%{t | strikethrough: false}, r)
  defp apply_sgr(t, [n | r]) when n >= 30 and n <= 37, do: apply_sgr(%{t | fg: "#{n}"}, r)
  defp apply_sgr(t, [38, 5, n | r]), do: apply_sgr(%{t | fg: "38;5;#{n}"}, r)
  defp apply_sgr(t, [38, 2, rv, g, b | r]), do: apply_sgr(%{t | fg: "38;2;#{rv};#{g};#{b}"}, r)
  defp apply_sgr(t, [39 | r]), do: apply_sgr(%{t | fg: nil}, r)
  defp apply_sgr(t, [n | r]) when n >= 40 and n <= 47, do: apply_sgr(%{t | bg: "#{n}"}, r)
  defp apply_sgr(t, [48, 5, n | r]), do: apply_sgr(%{t | bg: "48;5;#{n}"}, r)
  defp apply_sgr(t, [48, 2, rv, g, b | r]), do: apply_sgr(%{t | bg: "48;2;#{rv};#{g};#{b}"}, r)
  defp apply_sgr(t, [49 | r]), do: apply_sgr(%{t | bg: nil}, r)
  defp apply_sgr(t, [n | r]) when n >= 90 and n <= 97, do: apply_sgr(%{t | fg: "#{n}"}, r)
  defp apply_sgr(t, [n | r]) when n >= 100 and n <= 107, do: apply_sgr(%{t | bg: "#{n}"}, r)
  defp apply_sgr(t, [_ | r]), do: apply_sgr(t, r)

  defp apply_hyperlink(t, code) do
    body =
      code
      |> String.replace_prefix("\e]8;", "")
      |> String.replace_suffix("\e\\", "")
      |> String.replace_suffix(<<0x07>>, "")

    case String.split(body, ";", parts: 2) do
      [_params, ""] -> %{t | hyperlink: nil}
      [_params, url] -> %{t | hyperlink: url}
      _ -> t
    end
  end
end
