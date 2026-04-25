defmodule OctoPi.TUI.Renderer do
  @moduledoc """
  Differential screen renderer with viewport scrolling.

  Receives the full line buffer from the caller (no cropping).
  Internally computes `viewport_top = max(0, len - height)` so the
  viewport is always anchored to the bottom. Diffs at buffer-absolute
  indices for stability, but only paints lines within the visible
  viewport.

  Full-redraw triggers: first render, dimension change, content
  shrink, or a change above the viewport (in scrollback). Under
  Termux (detected via `TERMUX_VERSION`), height-only changes
  suppress the clear-screen.

  Each changed line is cleared with `\\e[2K` (erase entire line)
  before painting, matching upstream pi-mono.

  CSI 2026 (synchronized output) wrapping is opt-in via
  `:csi_2026?` at start_link time.
  """

  use GenServer

  @clear_screen "\e[2J\e[3J"
  @cursor_home "\e[H"
  @erase_below "\e[J"
  @erase_line "\e[2K"
  @sync_on "\e[?2026h"
  @sync_off "\e[?2026l"

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Render a list of lines. Returns the bytes to write.

  Lines may exceed the terminal height — the renderer computes the
  viewport internally. An optional `cursor_seq` (e.g. `"\\e[5;3H"`)
  is appended inside the sync block so the cursor move is atomic
  with the frame update.
  """
  @spec render(GenServer.server(), [binary()], binary()) :: {:ok, binary()}
  def render(pid, lines, cursor_seq \\ "")

  def render(pid, lines, cursor_seq) when is_list(lines),
    do: GenServer.call(pid, {:render, lines, cursor_seq})

  @doc "Update the terminal dimensions. Next render is a full redraw."
  @spec resize(GenServer.server(), pos_integer(), pos_integer()) :: :ok
  def resize(pid, width, height), do: GenServer.call(pid, {:resize, width, height})

  @doc "Return the number of full-redraw passes performed since start."
  @spec full_redraws(GenServer.server()) :: non_neg_integer()
  def full_redraws(pid), do: GenServer.call(pid, :full_redraws)

  @doc """
  Pure function used by the diff path and exposed for unit tests.
  Returns `{first_changed_index, last_changed_index}`. When nothing
  changed, returns `{-1, -1}`. Compares index-by-index using
  `max(length(new), length(old))`, treating out-of-bounds as `""`.
  """
  @spec find_diff_range([binary()], [binary()]) :: {integer(), integer()}
  def find_diff_range(new_lines, old_lines) do
    max_len = max(length(new_lines), length(old_lines))
    find_diff_range(new_lines, old_lines, 0, max_len, -1, -1)
  end

  defp find_diff_range(_new, _old, i, max_len, first, last) when i >= max_len,
    do: {first, last}

  defp find_diff_range(new, old, i, max_len, first, last) do
    new_line = Enum.at(new, i, "")
    old_line = Enum.at(old, i, "")

    {first, last} =
      if new_line != old_line do
        {if(first == -1, do: i, else: first), i}
      else
        {first, last}
      end

    find_diff_range(new, old, i + 1, max_len, first, last)
  end

  # --- GenServer callbacks ---

  @impl true
  def init(opts) do
    state = %{
      previous: nil,
      width: Keyword.get(opts, :width, 80),
      height: Keyword.get(opts, :height, 24),
      viewport_top: 0,
      csi_2026?: Keyword.get(opts, :csi_2026?, false),
      termux?: termux?(),
      full_redraws: 0
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:render, lines, cursor_seq}, _from, state) do
    {bytes, new_state} = compute(lines, cursor_seq, state)
    {:reply, {:ok, bytes}, new_state}
  end

  def handle_call({:resize, w, h}, _from, state) do
    suppress? = state.termux? and w == state.width
    new_prev = if suppress?, do: state.previous, else: nil
    {:reply, :ok, %{state | width: w, height: h, previous: new_prev}}
  end

  def handle_call(:full_redraws, _from, state),
    do: {:reply, state.full_redraws, state}

  # --- compute dispatch ---

  defp compute(lines, cursor_seq, %{previous: nil} = state),
    do: full_redraw(lines, cursor_seq, state)

  defp compute(lines, cursor_seq, %{previous: prev} = state)
       when length(lines) < length(prev),
       do: full_redraw(lines, cursor_seq, state)

  defp compute(lines, cursor_seq, state), do: diff(lines, cursor_seq, state)

  # --- full redraw ---

  defp full_redraw(lines, cursor_seq, state) do
    vp_top = viewport_top(lines, state.height)
    visible = viewport_slice(lines, vp_top, state.height)

    body = [
      @clear_screen,
      @cursor_home,
      render_visible(visible),
      @erase_below,
      cursor_seq
    ]

    bytes = IO.iodata_to_binary(wrap_sync(body, state))

    new_state = %{
      state
      | previous: lines,
        viewport_top: vp_top,
        full_redraws: state.full_redraws + 1
    }

    {bytes, new_state}
  end

  # --- diff ---

  defp diff(lines, cursor_seq, %{viewport_top: old_vp_top} = state) do
    new_vp_top = viewport_top(lines, state.height)

    if new_vp_top != old_vp_top do
      repaint_viewport(lines, cursor_seq, new_vp_top, state)
    else
      diff_within_viewport(lines, cursor_seq, new_vp_top, state)
    end
  end

  defp repaint_viewport(lines, cursor_seq, new_vp_top, state) do
    vp_bottom = new_vp_top + state.height - 1
    paint_last = min(vp_bottom, length(lines) - 1)

    body = paint_range(lines, new_vp_top, paint_last, new_vp_top) ++ [@erase_below, cursor_seq]
    bytes = IO.iodata_to_binary(wrap_sync(body, state))
    {bytes, %{state | previous: lines, viewport_top: new_vp_top}}
  end

  defp diff_within_viewport(lines, cursor_seq, new_vp_top, state) do
    case find_diff_range(lines, state.previous) do
      {-1, -1} ->
        if cursor_seq == "" do
          {"", %{state | previous: lines, viewport_top: new_vp_top}}
        else
          bytes = IO.iodata_to_binary(wrap_sync([cursor_seq], state))
          {bytes, %{state | previous: lines, viewport_top: new_vp_top}}
        end

      {first, _last} when first < new_vp_top ->
        full_redraw(lines, cursor_seq, state)

      {first, last} ->
        vp_bottom = new_vp_top + state.height - 1
        paint_first = max(first, new_vp_top)
        paint_last = min(last, vp_bottom)

        body =
          if paint_first > paint_last do
            [cursor_seq]
          else
            paint_range(lines, paint_first, paint_last, new_vp_top) ++ [cursor_seq]
          end

        bytes = IO.iodata_to_binary(wrap_sync(body, state))
        {bytes, %{state | previous: lines, viewport_top: new_vp_top}}
    end
  end

  # --- viewport helpers ---

  defp viewport_top(lines, height), do: max(0, length(lines) - height)

  defp viewport_slice(lines, vp_top, height) do
    Enum.slice(lines, vp_top, height)
  end

  # --- output helpers ---

  defp render_visible([]), do: []

  defp render_visible([line]), do: [@erase_line, line]

  defp render_visible([line | rest]),
    do: [@erase_line, line, "\r\n" | render_visible(rest)]

  defp paint_range(lines, first, last, vp_top) do
    Enum.flat_map(first..last, fn i ->
      screen_row = i - vp_top + 1
      line = Enum.at(lines, i, "")
      [move_to(screen_row, 1), @erase_line, line]
    end)
  end

  defp move_to(row, col), do: "\e[#{row};#{col}H"

  defp wrap_sync(body, %{csi_2026?: true}), do: [@sync_on, body, @sync_off]
  defp wrap_sync(body, %{csi_2026?: false}), do: body

  defp termux?, do: System.get_env("TERMUX_VERSION") != nil
end
