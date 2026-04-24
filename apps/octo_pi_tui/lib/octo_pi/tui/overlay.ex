defmodule OctoPi.TUI.Overlay do
  @moduledoc """
  Overlay positioning and compositing. An overlay is a rectangular
  region placed on top of a base screen at a computed position.
  """

  alias OctoPi.TUI.WrapAnsi

  @type size_value :: non_neg_integer() | {non_neg_integer(), :percent}

  @type anchor ::
          :center
          | :top_left
          | :top_right
          | :bottom_left
          | :bottom_right
          | :top_center
          | :bottom_center
          | :left_center
          | :right_center

  @type margin ::
          non_neg_integer()
          | %{top: integer(), right: integer(), bottom: integer(), left: integer()}

  @type t :: %__MODULE__{
          lines: [String.t()],
          width: size_value() | nil,
          min_width: non_neg_integer() | nil,
          max_height: size_value() | nil,
          anchor: anchor(),
          offset_x: integer(),
          offset_y: integer(),
          row: size_value() | nil,
          col: size_value() | nil,
          margin: margin(),
          z: non_neg_integer()
        }

  defstruct lines: [],
            width: nil,
            min_width: nil,
            max_height: nil,
            anchor: :center,
            offset_x: 0,
            offset_y: 0,
            row: nil,
            col: nil,
            margin: 0,
            z: 0

  # --- public API ---

  @doc "Compose overlays onto base lines. Overlays are painted in z-order (lowest first)."
  @spec composite([String.t()], [t()], pos_integer(), pos_integer()) :: [String.t()]
  def composite(base_lines, [], _width, _height), do: base_lines

  def composite(base_lines, overlays, term_w, term_h) do
    sorted = Enum.sort_by(overlays, & &1.z)

    rendered =
      Enum.map(sorted, fn ov ->
        {row, col, w, lines} = resolve_and_clip(ov, term_w, term_h)
        {row, col, w, lines}
      end)

    min_needed =
      rendered
      |> Enum.map(fn {row, _col, _w, lines} -> row + length(lines) end)
      |> Enum.max(fn -> 0 end)

    working_height = max(length(base_lines), max(term_h, min_needed))
    result = pad_lines(base_lines, working_height)
    viewport_start = max(0, working_height - term_h)

    Enum.reduce(rendered, result, fn {row, col, w, lines}, acc ->
      paint_overlay(acc, lines, viewport_start + row, col, w, term_w)
    end)
  end

  @doc "Resolve an overlay's layout to `{row, col, width, clipped_lines}`."
  @spec resolve_and_clip(t(), pos_integer(), pos_integer()) ::
          {non_neg_integer(), non_neg_integer(), pos_integer(), [String.t()]}
  def resolve_and_clip(%__MODULE__{} = ov, term_w, term_h) do
    {mt, mr, mb, ml} = parse_margin(ov.margin)
    avail_w = max(1, term_w - ml - mr)
    avail_h = max(1, term_h - mt - mb)

    w = resolve_width(ov.width, term_w, avail_w, ov.min_width)
    mh = resolve_max_height(ov.max_height, term_h, avail_h)

    lines = clip_lines(ov.lines, mh)
    eff_h = length(lines)

    row = resolve_row(ov, eff_h, avail_h, mt, term_h, mb)
    col = resolve_col(ov, w, avail_w, ml, term_w, mr)

    {row, col, w, lines}
  end

  @doc "Resolve anchor position to a concrete row."
  @spec anchor_row(anchor(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def anchor_row(anchor, height, avail_h, margin_top)

  def anchor_row(a, _h, _ah, mt) when a in [:top_left, :top_center, :top_right], do: mt

  def anchor_row(a, h, ah, mt) when a in [:bottom_left, :bottom_center, :bottom_right],
    do: mt + ah - h

  def anchor_row(_a, h, ah, mt), do: mt + div(ah - h, 2)

  @doc "Resolve anchor position to a concrete column."
  @spec anchor_col(anchor(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          non_neg_integer()
  def anchor_col(anchor, width, avail_w, margin_left)

  def anchor_col(a, _w, _aw, ml) when a in [:top_left, :left_center, :bottom_left], do: ml

  def anchor_col(a, w, aw, ml) when a in [:top_right, :right_center, :bottom_right],
    do: ml + aw - w

  def anchor_col(_a, w, aw, ml), do: ml + div(aw - w, 2)

  # --- internals ---

  defp parse_margin(n) when is_integer(n) do
    v = max(0, n)
    {v, v, v, v}
  end

  defp parse_margin(%{} = m) do
    {max(0, Map.get(m, :top, 0)), max(0, Map.get(m, :right, 0)), max(0, Map.get(m, :bottom, 0)),
     max(0, Map.get(m, :left, 0))}
  end

  defp resolve_width(nil, _tw, avail_w, min_w) do
    w = min(80, avail_w)
    apply_min_width(w, min_w, avail_w)
  end

  defp resolve_width({pct, :percent}, tw, avail_w, min_w) do
    w = div(tw * pct, 100)
    apply_min_width(w, min_w, avail_w) |> clamp(1, avail_w)
  end

  defp resolve_width(abs, _tw, avail_w, min_w) when is_integer(abs) do
    apply_min_width(abs, min_w, avail_w) |> clamp(1, avail_w)
  end

  defp apply_min_width(w, nil, _avail_w), do: w
  defp apply_min_width(w, min_w, _avail_w), do: max(w, min_w)

  defp resolve_max_height(nil, _th, _ah), do: nil
  defp resolve_max_height({pct, :percent}, th, ah), do: clamp(div(th * pct, 100), 1, ah)
  defp resolve_max_height(abs, _th, ah) when is_integer(abs), do: clamp(abs, 1, ah)

  defp clip_lines(lines, nil), do: lines
  defp clip_lines(lines, mh), do: Enum.take(lines, mh)

  defp resolve_row(ov, eff_h, avail_h, mt, term_h, mb) do
    base =
      case ov.row do
        nil -> anchor_row(ov.anchor, eff_h, avail_h, mt)
        {pct, :percent} -> mt + div(max(0, avail_h - eff_h) * pct, 100)
        abs when is_integer(abs) -> abs
      end

    clamp(base + ov.offset_y, mt, term_h - mb - eff_h)
  end

  defp resolve_col(ov, w, avail_w, ml, term_w, mr) do
    base =
      case ov.col do
        nil -> anchor_col(ov.anchor, w, avail_w, ml)
        {pct, :percent} -> ml + div(max(0, avail_w - w) * pct, 100)
        abs when is_integer(abs) -> abs
      end

    clamp(base + ov.offset_x, ml, term_w - mr - w)
  end

  defp paint_overlay(result, lines, start_row, col, w, term_w) do
    lines
    |> Enum.with_index(start_row)
    |> Enum.reduce(result, fn {ov_line, idx}, acc ->
      if idx >= 0 and idx < length(acc) do
        base = Enum.at(acc, idx)
        List.replace_at(acc, idx, composite_line(base, ov_line, col, w, term_w))
      else
        acc
      end
    end)
  end

  @doc false
  def composite_line(base, overlay, col, w, term_w) do
    before = slice_visible(base, 0, col)
    before_w = WrapAnsi.visible_width(before)
    before_pad = max(0, col - before_w)

    ov_clipped = slice_visible(overlay, 0, w)
    ov_w = WrapAnsi.visible_width(ov_clipped)
    ov_pad = max(0, w - ov_w)

    after_start = col + w
    after_len = max(0, term_w - after_start)
    after_text = slice_visible(base, after_start, after_len)
    after_w = WrapAnsi.visible_width(after_text)
    after_pad = max(0, after_len - after_w)

    reset = "\e[0m"

    result =
      before <>
        String.duplicate(" ", before_pad) <>
        reset <>
        ov_clipped <>
        String.duplicate(" ", ov_pad) <>
        reset <>
        after_text <>
        String.duplicate(" ", after_pad)

    rw = WrapAnsi.visible_width(result)
    if rw > term_w, do: slice_visible(result, 0, term_w), else: result
  end

  defp slice_visible(str, start, len) when len <= 0 and start == 0, do: ""
  defp slice_visible(_str, _start, len) when len <= 0, do: ""

  defp slice_visible(str, start, len) do
    str
    |> do_slice(start, len, 0, "", false)
  end

  defp do_slice("", _start, _len, _col, acc, _in_range), do: acc

  defp do_slice(<<"\e", _::binary>> = input, start, len, col, acc, in_range) do
    {code, rest} = extract_escape(input)

    if in_range do
      do_slice(rest, start, len, col, acc <> code, in_range)
    else
      do_slice(rest, start, len, col, acc, in_range)
    end
  end

  defp do_slice(bin, start, len, col, acc, in_range) do
    case String.next_grapheme(bin) do
      nil ->
        acc

      {g, rest} ->
        w = WrapAnsi.grapheme_width(g)
        end_col = start + len

        cond do
          col >= end_col ->
            acc

          col >= start ->
            if col + w <= end_col do
              do_slice(rest, start, len, col + w, acc <> g, true)
            else
              acc
            end

          col + w > start ->
            do_slice(rest, start, len, col + w, acc, in_range)

          true ->
            do_slice(rest, start, len, col + w, acc, in_range)
        end
    end
  end

  defp extract_escape(<<"\e[", rest::binary>>) do
    {body, remaining} = take_csi(rest)
    {"\e[" <> body, remaining}
  end

  defp extract_escape(<<"\e]", rest::binary>>) do
    {body, remaining} = take_osc(rest)
    {"\e]" <> body, remaining}
  end

  defp extract_escape(<<"\e", c::8, rest::binary>>), do: {<<"\e", c>>, rest}
  defp extract_escape(<<c::8, rest::binary>>), do: {<<c>>, rest}

  defp take_csi(<<>>), do: {"", ""}
  defp take_csi(<<b::8, rest::binary>>) when b >= 0x40 and b <= 0x7E, do: {<<b>>, rest}

  defp take_csi(<<b::8, rest::binary>>) do
    {tail, rem} = take_csi(rest)
    {<<b>> <> tail, rem}
  end

  defp take_osc(<<>>), do: {"", ""}
  defp take_osc(<<0x07, rest::binary>>), do: {<<0x07>>, rest}
  defp take_osc(<<"\e\\", rest::binary>>), do: {"\e\\", rest}

  defp take_osc(<<b::8, rest::binary>>) do
    {tail, rem} = take_osc(rest)
    {<<b>> <> tail, rem}
  end

  defp pad_lines(lines, target) do
    deficit = target - length(lines)
    if deficit > 0, do: lines ++ List.duplicate("", deficit), else: lines
  end

  defp clamp(v, lo, hi), do: max(lo, min(v, hi))
end
