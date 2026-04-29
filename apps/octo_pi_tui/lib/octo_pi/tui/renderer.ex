defmodule OctoPi.TUI.Renderer do
  @moduledoc """
  Scroll-based differential screen renderer — pure functional module.

  Writes **all** lines to the terminal and lets it scroll naturally,
  keeping content in the scrollback buffer. Uses relative cursor
  movement (`\\e[nA` / `\\e[nB`) for diff updates — never absolute
  row positioning — so the terminal's own viewport tracking stays
  consistent.

  Rendering modes, matching upstream pi-mono:

    1. **First render** — output all lines, no clear.
    2. **Width change** — clear screen + scrollback, re-render everything.
    3. **Height change** — same (except Termux, where height-only changes
       are suppressed to avoid keyboard-toggle flicker).
    4. **Content shrink** — clear + re-render when `clear_on_shrink` is
       set and no overlays are active.
    5. **Normal diff** — find first/last changed line, move cursor there
       via relative movement, re-render the changed range.

  If the first changed line is above the visible viewport (user
  scrolled up), a full clear + re-render is required because the
  terminal won't let us write into the scrollback buffer.

  CSI 2026 (synchronized output) wrapping is opt-in via
  `:csi_2026?` at construction time.
  """

  alias OctoPi.TUI.Terminal.Image

  require Logger

  @clear_screen "\e[2J\e[H\e[3J"
  @erase_line "\e[2K"
  @sync_on "\e[?2026h"
  @sync_off "\e[?2026l"

  @enforce_keys []
  defstruct previous: nil,
            width: 80,
            height: 24,
            hardware_cursor_row: 0,
            max_lines_rendered: 0,
            previous_viewport_top: 0,
            needs_clear: false,
            csi_2026?: false,
            termux?: false,
            full_redraws: 0,
            clear_on_shrink: false,
            cell_dims: %{width_px: 9, height_px: 18}

  @type t :: %__MODULE__{
          previous: [binary()] | nil,
          width: pos_integer(),
          height: pos_integer(),
          hardware_cursor_row: non_neg_integer(),
          max_lines_rendered: non_neg_integer(),
          previous_viewport_top: non_neg_integer(),
          needs_clear: boolean(),
          csi_2026?: boolean(),
          termux?: boolean(),
          full_redraws: non_neg_integer(),
          clear_on_shrink: boolean(),
          cell_dims: %{width_px: non_neg_integer(), height_px: non_neg_integer()}
        }

  # --- public API ---

  @doc "Create a new renderer struct."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      csi_2026?: Keyword.get(opts, :csi_2026?, false),
      termux?: termux?(),
      clear_on_shrink: System.get_env("PI_CLEAR_ON_SHRINK") == "1"
    }
  end

  @doc """
  Render a list of lines. Returns `{bytes, new_renderer}`.

  Lines may exceed the terminal height — the renderer writes them
  all to the terminal. An optional `cursor_seq` positions the
  hardware cursor (for IME) after the frame update.
  """
  @spec render(t(), [binary()], binary(), keyword()) :: {binary(), t()}
  def render(r, lines, cursor_seq \\ "", opts \\ [])

  def render(r, lines, cursor_seq, _opts) when is_list(lines) do
    text_lines = Enum.reject(lines, &Image.image_line?/1)

    case check_width_overflow(text_lines, r.width) do
      {:overflow, overflows} ->
        Logger.warning("Renderer: #{length(overflows)} line(s) exceed terminal width #{r.width}")

      :ok ->
        :ok
    end

    compute(lines, cursor_seq, r)
  end

  @doc "Update the terminal dimensions. Returns a new renderer; next render is a full redraw."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(r, w, h) do
    width_changed = w != r.width
    height_changed = h != r.height
    suppress? = r.termux? and not width_changed and height_changed

    if suppress? do
      %{r | width: w, height: h}
    else
      %{r | width: w, height: h, previous: nil, needs_clear: true}
    end
  end

  @doc "Update terminal cell pixel dimensions (used to size images in rows)."
  @spec set_cell_dims(t(), %{width_px: non_neg_integer(), height_px: non_neg_integer()}) :: t()
  def set_cell_dims(r, dims), do: %{r | cell_dims: dims}

  @doc """
  Return bytes that move the cursor to just past the last rendered line.
  Write these to the terminal before exit so the shell prompt appears on
  a fresh line below the content.
  """
  @spec exit_bytes(t()) :: binary()
  def exit_bytes(%__MODULE__{previous: nil}), do: ""

  def exit_bytes(r) do
    target_row = length(r.previous)
    line_diff = target_row - r.hardware_cursor_row
    IO.iodata_to_binary([move_cursor_v(line_diff), "\r\n"])
  end

  @doc """
  Pure diff helper exposed for unit tests.
  Returns `{first_changed, last_changed}` or `{-1, -1}` when identical.
  """
  @spec find_diff_range([binary()], [binary()]) :: {integer(), integer()}
  def find_diff_range(new_lines, old_lines) do
    max_len = max(length(new_lines), length(old_lines))
    do_find_diff(new_lines, old_lines, 0, max_len, -1, -1)
  end

  defp do_find_diff(_new, _old, i, max_len, first, last) when i >= max_len, do: {first, last}

  defp do_find_diff(new, old, i, max_len, first, last) do
    new_line = Enum.at(new, i, "")
    old_line = Enum.at(old, i, "")

    {first, last} =
      if new_line == old_line do
        {first, last}
      else
        {if(first == -1, do: i, else: first), i}
      end

    do_find_diff(new, old, i + 1, max_len, first, last)
  end

  # --- compute dispatch ---

  defp compute(lines, cursor_seq, %{previous: nil, needs_clear: clear} = r) do
    full_render(lines, cursor_seq, %{r | needs_clear: false}, clear)
  end

  defp compute(lines, cursor_seq, r) do
    if r.clear_on_shrink and length(lines) < r.max_lines_rendered do
      full_render(lines, cursor_seq, r, true)
    else
      diff_render(lines, cursor_seq, r)
    end
  end

  # --- full render ---

  defp full_render(lines, cursor_seq, r, clear) do
    body =
      if clear do
        [@clear_screen | render_all_lines(lines)]
      else
        render_all_lines(lines)
      end

    content_end_row = max(0, length(lines) - 1)
    {cursor_iodata, hw_row} = position_cursor(cursor_seq, content_end_row, lines, r.height)
    body = body ++ [cursor_iodata]
    bytes = IO.iodata_to_binary(wrap_sync(body, r))

    max_lines =
      if clear, do: length(lines), else: max(r.max_lines_rendered, length(lines))

    buffer_length = max(r.height, length(lines))

    new_r = %{
      r
      | previous: lines,
        hardware_cursor_row: hw_row,
        max_lines_rendered: max_lines,
        previous_viewport_top: max(0, buffer_length - r.height),
        full_redraws: r.full_redraws + 1
    }

    {bytes, new_r}
  end

  defp render_all_lines([]), do: []
  defp render_all_lines([line]), do: [line]
  defp render_all_lines([line | rest]), do: [line, "\r\n" | render_all_lines(rest)]

  # --- differential render ---

  defp diff_render(lines, cursor_seq, r) do
    height = r.height
    prev = r.previous
    prev_len = length(prev)
    new_len = length(lines)

    {first_changed, last_changed} = find_diff_range(lines, prev)

    appended = new_len > prev_len

    {first_changed, last_changed} =
      if appended do
        fc = if first_changed == -1, do: prev_len, else: first_changed
        {fc, new_len - 1}
      else
        {first_changed, last_changed}
      end

    prev_vp_top = r.previous_viewport_top
    hw_cursor = r.hardware_cursor_row

    cond do
      first_changed == -1 ->
        {cursor_iodata, hw_row} = position_cursor(cursor_seq, hw_cursor, lines, height)
        body = [cursor_iodata]
        bytes = IO.iodata_to_binary(wrap_sync(body, r))

        {bytes,
         %{
           r
           | previous: lines,
             previous_viewport_top: prev_vp_top,
             hardware_cursor_row: hw_row
         }}

      first_changed >= new_len and prev_len > new_len ->
        handle_deleted_lines(lines, cursor_seq, r, first_changed, prev_vp_top, hw_cursor)

      first_changed < prev_vp_top ->
        full_render(lines, cursor_seq, r, true)

      true ->
        handle_changed_lines(
          lines,
          cursor_seq,
          r,
          first_changed,
          last_changed,
          appended,
          prev_vp_top,
          hw_cursor
        )
    end
  end

  defp handle_deleted_lines(lines, cursor_seq, r, _first, prev_vp_top, hw_cursor) do
    new_len = length(lines)
    prev_len = length(r.previous)
    target_row = max(0, new_len - 1)
    lines_to_clear = prev_len - max(new_len, 1)

    cond do
      target_row < prev_vp_top ->
        full_render(lines, cursor_seq, r, true)

      lines_to_clear > r.height ->
        full_render(lines, cursor_seq, r, true)

      true ->
        emit_deleted_lines(lines, cursor_seq, r, target_row, lines_to_clear, prev_vp_top, hw_cursor)
    end
  end

  defp emit_deleted_lines(lines, cursor_seq, r, target_row, lines_to_clear, prev_vp_top, hw_cursor) do
    new_len = length(lines)
    prev_len = length(r.previous)
    move = target_row - prev_vp_top - (hw_cursor - prev_vp_top)
    cursor_target = if new_len == 0, do: 0, else: target_row
    {cursor_iodata, hw_row} = position_cursor(cursor_seq, cursor_target, lines, r.height)

    body = deleted_lines_body(new_len, move, prev_len, lines_to_clear, cursor_iodata)
    bytes = IO.iodata_to_binary(wrap_sync(body, r))

    new_r = %{
      r
      | previous: lines,
        hardware_cursor_row: hw_row,
        previous_viewport_top: prev_vp_top
    }

    {bytes, new_r}
  end

  defp deleted_lines_body(0, move, prev_len, _lines_to_clear, cursor_iodata) do
    [
      move_cursor_v(move),
      "\r",
      clear_n_lines(prev_len),
      if(prev_len > 1, do: "\e[#{prev_len - 1}A", else: ""),
      cursor_iodata
    ]
  end

  defp deleted_lines_body(_new_len, move, _prev_len, lines_to_clear, cursor_iodata) do
    [
      move_cursor_v(move),
      if(lines_to_clear > 0, do: "\e[1B", else: ""),
      clear_n_lines(lines_to_clear),
      if(lines_to_clear > 0, do: "\e[#{lines_to_clear}A", else: ""),
      cursor_iodata
    ]
  end

  defp handle_changed_lines(lines, cursor_seq, r, first_changed, last_changed, appended, prev_vp_top, hw_cursor) do
    height = r.height
    append_start = appended and first_changed == length(r.previous) and first_changed > 0
    move_target = if append_start, do: first_changed - 1, else: first_changed

    {body_prefix, prev_vp_top, viewport_top, hw_cursor} =
      maybe_scroll_viewport(move_target, prev_vp_top, height, hw_cursor)

    line_diff = move_target - viewport_top - (hw_cursor - prev_vp_top)
    sep = if append_start, do: "\r\n", else: "\r"
    render_end = min(last_changed, length(lines) - 1)

    changed_body =
      first_changed..render_end
      |> Enum.with_index()
      |> Enum.flat_map(fn {i, idx} ->
        line = Enum.at(lines, i, "")
        prefix = if idx > 0, do: "\r\n", else: ""
        [prefix, @erase_line, line]
      end)

    cleanup = build_cleanup(r.previous, lines, render_end)
    {cursor_iodata, hw_row} = position_cursor(cursor_seq, render_end, lines, height)

    body =
      body_prefix ++
        [move_cursor_v(line_diff), sep] ++
        changed_body ++
        cleanup ++
        [cursor_iodata]

    bytes = IO.iodata_to_binary(wrap_sync(body, r))
    new_vp_top = max(prev_vp_top, hw_row - height + 1)

    new_r = %{
      r
      | previous: lines,
        hardware_cursor_row: hw_row,
        max_lines_rendered: length(lines),
        previous_viewport_top: new_vp_top
    }

    {bytes, new_r}
  end

  defp maybe_scroll_viewport(move_target, prev_vp_top, height, hw_cursor) do
    prev_vp_bottom = prev_vp_top + height - 1

    if move_target > prev_vp_bottom do
      current_screen_row = max(0, min(height - 1, hw_cursor - prev_vp_top))
      move_to_bottom = height - 1 - current_screen_row
      scroll = move_target - prev_vp_bottom

      prefix = [
        move_cursor_v(move_to_bottom),
        String.duplicate("\r\n", scroll)
      ]

      {prefix, prev_vp_top + scroll, prev_vp_top + scroll, move_target}
    else
      {[], prev_vp_top, prev_vp_top, hw_cursor}
    end
  end

  defp build_cleanup(previous, lines, render_end) when length(previous) > length(lines) do
    extra = length(previous) - length(lines)
    remaining = length(lines) - 1 - render_end

    move_down =
      if remaining > 0, do: ["\e[#{remaining}B"], else: []

    clear =
      for _ <- 1..extra, do: "\r\n#{@erase_line}"

    move_back = ["\e[#{extra}A"]
    move_down ++ clear ++ move_back
  end

  defp build_cleanup(_previous, _lines, _render_end), do: []

  # --- cursor positioning ---

  defp position_cursor("", hw_row, _lines, _height), do: {"", hw_row}

  defp position_cursor(cursor_seq, hw_row, lines, height) do
    case Regex.run(~r/\e\[(\d+);(\d+)H/, cursor_seq) do
      [_, row_s, col_s] ->
        screen_row = String.to_integer(row_s) - 1
        viewport_top = max(0, length(lines) - height)
        buffer_row = viewport_top + screen_row
        col = String.to_integer(col_s)
        row_delta = buffer_row - hw_row
        {[move_cursor_v(row_delta), "\e[#{col}G"], buffer_row}

      _ ->
        {cursor_seq, hw_row}
    end
  end

  # --- helpers ---

  defp check_width_overflow(lines, width) do
    overflows =
      lines
      |> Enum.with_index()
      |> Enum.reduce([], fn {line, idx}, acc ->
        visible_len = line |> strip_ansi() |> String.length()
        if visible_len > width, do: [{idx, visible_len} | acc], else: acc
      end)
      |> Enum.reverse()

    case overflows do
      [] -> :ok
      list -> {:overflow, list}
    end
  end

  defp strip_ansi(text), do: Regex.replace(~r/\e\[[0-9;]*[A-Za-z]/, text, "")

  defp move_cursor_v(0), do: ""
  defp move_cursor_v(n) when n > 0, do: "\e[#{n}B"
  defp move_cursor_v(n) when n < 0, do: "\e[#{-n}A"

  defp clear_n_lines(0), do: ""

  defp clear_n_lines(n) do
    Enum.map_join(1..n, fn i ->
      suffix = if i < n, do: "\e[1B", else: ""
      "\r#{@erase_line}#{suffix}"
    end)
  end

  defp wrap_sync(body, %{csi_2026?: true}), do: [@sync_on, body, @sync_off]
  defp wrap_sync(body, %{csi_2026?: false}), do: body

  defp termux?, do: System.get_env("TERMUX_VERSION") != nil
end
