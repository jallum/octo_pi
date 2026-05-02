defmodule OctoPi.TUI.VDOM.Paint do
  @moduledoc """
  Single-pass paint walker for VNode trees.

  The entry point is `paint/3`; it dispatches on struct type and recurses
  via `paint_kids/3` and `paint_inline_kids/3` which handle iodata-shaped
  children without list materialization.

  Rules:
    - No `++`, `flat_map`, `List.flatten`.
    - Multi-head pattern matching, not top-level `case`.
    - VMemo cache hits splice iodata and apply cursor offset.
  """

  import OctoPi.TUI.VDOM, only: [is_vnode: 1]

  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.VDOM.LineBuf

  require Logger

  @doc "Paint a single VNode onto a LineBuf."
  @spec paint(VDOM.t(), LineBuf.t(), RenderCtx.t()) :: LineBuf.t()
  def paint(%VDOM.VText{text: text, width: _width}, buf, _ctx) do
    LineBuf.push(buf, text)
  end

  def paint(%VDOM.VLines{lines: lines}, buf, _ctx) when is_list(lines) do
    paint_lines_enum(lines, buf)
  end

  def paint(%VDOM.VFlow{children: children}, buf, ctx) do
    children |> paint_kids(buf, ctx) |> maybe_flush_line()
  end

  def paint(%VDOM.VRow{children: children}, buf, ctx) do
    paint_inline_kids(children, buf, ctx)
  end

  def paint(%VDOM.VBox{border?: border, padding_x: px, padding_y: py, children: children}, buf, ctx) do
    width = ctx.width
    border_line = if border, do: String.duplicate("─", max(1, width))

    buf =
      if border do
        buf |> LineBuf.push("┌" <> border_line <> "┐") |> LineBuf.flush_line()
      else
        buf
      end

    buf = pad_vertical(buf, py, width, border)
    buf = pad_horizontal_open(buf, px, border)
    buf = paint_kids(children, buf, ctx)
    buf = pad_horizontal_close(buf, px, border)
    buf = pad_vertical(buf, py, width, border)

    if border do
      buf |> LineBuf.push("└" <> border_line <> "┘") |> LineBuf.flush_line()
    else
      buf
    end
  end

  def paint(%VDOM.VZone{type: _type, id: _id, children: children}, buf, ctx) do
    open = "\e]133;A\a"
    close = "\e]133;B\a\e]133;C\a"

    before = buf.line_count
    buf = paint_kids(children, buf, ctx)
    after_count = buf.line_count

    if before == after_count do
      buf |> LineBuf.push(open) |> LineBuf.push(close) |> LineBuf.flush_line()
    else
      wrap_zone(buf, open, close, after_count - before)
    end
  end

  def paint(%VDOM.VMemo{key: key, thunk: thunk, cell: cell}, _buf, ctx) do
    # Read the reconciler cell; opaque to paint.
    # The cell stores memo data OR returns a miss signal.
    # {:hit, ...} clause suppressed until memo cell is wired (d06.10+);
    # read_memo_cell/2 currently always returns {:miss, nil}.
    {:miss, cell2} = read_memo_cell(cell, key)
    # Evaluate thunk and store result in cell.
    result = thunk.()
    {iodata, width, cursor_offset, painted} = paint_with_capture(result, ctx)
    write_memo_cell(cell2, key, {iodata, width, cursor_offset})
    painted
  end

  def paint(%VDOM.VHole{slot_id: _slot_id}, buf, _ctx) do
    # Holes are painted by Interactive root (not in this ticket).
    buf
  end

  def paint(%VDOM.VCursor{style: style}, buf, _ctx) do
    LineBuf.mark_cursor(buf, style)
  end

  ## Internals: kids walking

  # paint_kids recurses into children that are allowed to emit newlines.
  # Children is iodata: scalars, lists, or VNodes.
  @spec paint_kids(iodata(), LineBuf.t(), RenderCtx.t()) :: LineBuf.t()
  defp paint_kids(children, buf, ctx) when is_list(children) do
    # Fold over list elements without concatenating.
    Enum.reduce(children, buf, fn child, acc -> paint_kids(child, acc, ctx) end)
  end

  defp paint_kids(vnode, buf, ctx) when is_vnode(vnode) do
    paint(vnode, buf, ctx)
  end

  defp paint_kids(bin, buf, _ctx) when is_binary(bin) do
    # Plain text: split on newlines and flush.
    case :binary.split(bin, "\n", [:global]) do
      [single] -> LineBuf.push(buf, single)
      [first | rest] -> paint_split_lines(buf, first, rest)
    end
  end

  defp paint_kids(other, buf, _ctx) when is_integer(other) or is_atom(other) do
    # Numbers, atoms, etc.
    LineBuf.push(buf, to_string(other))
  end

  # paint_inline_kids is for VRow: children are concatenated on the same line.
  @spec paint_inline_kids(iodata(), LineBuf.t(), RenderCtx.t()) :: LineBuf.t()
  defp paint_inline_kids(children, buf, ctx) when is_list(children) do
    Enum.reduce(children, buf, fn child, acc -> paint_inline_kids(child, acc, ctx) end)
  end

  defp paint_inline_kids(vnode, buf, ctx) when is_vnode(vnode) do
    # VNodes inside a VRow must not emit newlines.
    paint(vnode, buf, ctx)
  end

  defp paint_inline_kids(bin, buf, _ctx) when is_binary(bin) do
    LineBuf.push(buf, bin)
  end

  defp paint_inline_kids(other, buf, _ctx) do
    LineBuf.push(buf, to_string(other))
  end

  ## Helpers

  defp maybe_flush_line(%{line_iolist_rev: []} = buf), do: buf
  defp maybe_flush_line(buf), do: LineBuf.flush_line(buf)

  defp paint_lines_enum([], buf), do: buf

  defp paint_lines_enum([line | rest], buf) do
    paint_lines_enum(rest, buf |> LineBuf.push(line) |> LineBuf.flush_line())
  end

  defp paint_split_lines(buf, first, [last]) do
    buf |> LineBuf.push(first) |> LineBuf.flush_line() |> LineBuf.push(last)
  end

  defp paint_split_lines(buf, first, [second | rest]) do
    buf |> LineBuf.push(first) |> LineBuf.flush_line() |> paint_split_lines(second, rest)
  end

  defp pad_vertical(buf, 0, _width, _border), do: buf

  defp pad_vertical(buf, py, width, border) do
    line = if border, do: String.duplicate(" ", max(2, width - 2)), else: String.duplicate(" ", width)
    Enum.reduce(1..py, buf, fn _, acc -> acc |> LineBuf.push(line) |> LineBuf.flush_line() end)
  end

  defp pad_horizontal_open(buf, 0, _border), do: buf

  defp pad_horizontal_open(buf, px, border) do
    pad = String.duplicate(" ", px)

    if border do
      LineBuf.push(buf, "│" <> pad)
    else
      LineBuf.push(buf, pad)
    end
  end

  defp pad_horizontal_close(buf, 0, border) do
    if border, do: buf |> LineBuf.push("│") |> LineBuf.flush_line(), else: LineBuf.flush_line(buf)
  end

  defp pad_horizontal_close(buf, px, border) do
    pad = String.duplicate(" ", px)

    if border do
      buf |> LineBuf.push(pad <> "│") |> LineBuf.flush_line()
    else
      buf |> LineBuf.push(pad) |> LineBuf.flush_line()
    end
  end

  defp wrap_zone(buf, _open, _close, 0), do: buf

  defp wrap_zone(buf, open, close, n) do
    first_idx = 2 * (n - 1)

    iolist_rev =
      buf.iolist_rev
      |> List.update_at(0, fn l -> [close | List.wrap(l)] end)
      |> List.update_at(first_idx, fn l -> [open | List.wrap(l)] end)

    %{buf | iolist_rev: iolist_rev}
  end

  ## Simulated memo cell (reconciler will replace this in d06.2)

  defp read_memo_cell(nil, _key), do: {:miss, nil}
  defp read_memo_cell(_cell, _key), do: {:miss, nil}

  defp write_memo_cell(_cell, _key, _value), do: :ok

  ## Paint-and-capture for memo

  defp paint_with_capture(children, ctx) do
    buf = LineBuf.new()
    buf2 = paint_kids(children, buf, ctx)
    {iolist, cursor} = LineBuf.finalize(buf2)

    width = if cursor, do: elem(cursor, 1), else: 0
    offset = if cursor, do: {buf2.line_count, width}

    {iolist, width, offset, buf2}
  end

  ## RenderCtx placeholder

  defmodule RenderCtx do
    @moduledoc "Render context threaded through paint."
    defstruct [:width]

    @type t :: %__MODULE__{width: pos_integer()}
  end
end
