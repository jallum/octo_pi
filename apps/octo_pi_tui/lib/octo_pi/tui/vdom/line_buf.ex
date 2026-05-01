defmodule OctoPi.TUI.VDOM.LineBuf do
  @moduledoc """
  iodata accumulator with visible-width tracking.

  The painter writes into a LineBuf; at frame end `finalize/1` returns
  `{iodata, cursor_or_nil}` ready for the legacy renderer.

  Layout:
    {iolist_rev, line_iolist_rev, visible_width, line_count, cursor}

    - iolist_rev: reversed list of completed lines (each is iodata)
    - line_iolist_rev: reversed list for the line currently being built
    - visible_width: visible width of current line (excluding ANSI)
    - line_count: total lines flushed so far
    - cursor: nil | {row, col} where row is absolute buffer row
  """

  alias OctoPi.TUI.WrapAnsi

  @type t :: %__MODULE__{
          iolist_rev: [iodata()],
          line_iolist_rev: [iodata()],
          visible_width: non_neg_integer(),
          line_count: non_neg_integer(),
          cursor: nil | {non_neg_integer(), non_neg_integer()}
        }

  defstruct iolist_rev: [],
            line_iolist_rev: [],
            visible_width: 0,
            line_count: 0,
            cursor: nil

  @doc "Create a fresh buffer."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Push a string or iodata onto the current line."
  @spec push(t(), iodata()) :: t()
  def push(%__MODULE__{} = buf, data) when is_binary(data) or is_list(data) do
    # For performance, we avoid IO.iodata_length/1 on the hot path.
    # Track visible width by scanning binaries only.
    width = visible_width_of(data)

    %{
      buf
      | line_iolist_rev: [data | buf.line_iolist_rev],
        visible_width: buf.visible_width + width
    }
  end

  @doc "Push many segments."
  @spec push_many(t(), [iodata()], non_neg_integer()) :: t()
  def push_many(%__MODULE__{} = buf, segments, total_width) do
    # Called by paint_kids when it knows the total width upfront.
    %{
      buf
      | line_iolist_rev: Enum.reverse(segments) ++ buf.line_iolist_rev,
        visible_width: buf.visible_width + total_width
    }
  end

  @doc "Flush the current line and start a new one."
  @spec flush_line(t()) :: t()
  def flush_line(%__MODULE__{} = buf) do
    # Build complete line as iodata and add to rev list
    line_iodata = Enum.reverse(buf.line_iolist_rev)

    %{
      buf
      | iolist_rev: [line_iodata, "\n" | buf.iolist_rev],
        line_iolist_rev: [],
        visible_width: 0,
        line_count: buf.line_count + 1
    }
  end

  @doc "Mark cursor position at the current line/col."
  @spec mark_cursor(t()) :: t()
  def mark_cursor(%__MODULE__{cursor: nil} = buf) do
    %{buf | cursor: {buf.line_count, buf.visible_width}}
  end

  def mark_cursor(%__MODULE__{} = buf), do: buf

  @doc "Finalize buffer, returning {iodata, cursor_or_nil}."
  @spec finalize(t()) :: {iodata(), nil | {non_neg_integer(), non_neg_integer()}}
  def finalize(%__MODULE__{line_iolist_rev: [], iolist_rev: []} = buf) do
    {[], buf.cursor}
  end

  def finalize(%__MODULE__{line_iolist_rev: []} = buf) do
    # Only previously flushed lines exist - already have newlines
    {Enum.reverse(buf.iolist_rev), buf.cursor}
  end

  def finalize(%__MODULE__{} = buf) do
    # Current line pending - don't add newline (caller should have flushed last line)
    line_iodata = Enum.reverse(buf.line_iolist_rev)
    iolist = Enum.reverse([line_iodata | buf.iolist_rev])
    {iolist, buf.cursor}
  end

  ## Helpers

  defp visible_width_of(bin) when is_binary(bin), do: WrapAnsi.visible_width(bin)

  defp visible_width_of(list) when is_list(list) do
    # Recursively count visible width without materializing iodata.
    Enum.reduce(list, 0, fn segment, acc -> acc + visible_width_of(segment) end)
  end
end