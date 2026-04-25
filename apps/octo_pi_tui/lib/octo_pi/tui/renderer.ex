defmodule OctoPi.TUI.Renderer do
  @moduledoc """
  Differential screen renderer. Holds the previous frame; on each
  `render/2`, computes a line-level diff against it, emits cursor
  repositioning + the changed range, and returns the bytes for
  the caller (usually `OctoPi.TUI.Terminal`) to write.

  Full-redraw triggers: first render, dimension change, line-count
  change. Under Termux (detected via `TERMUX_VERSION`), height-only
  changes suppress the clear-screen because Termux's console
  doesn't reflow the scrollback the same way xterm does.

  CSI 2026 (synchronized output) wrapping is opt-in via
  `:csi_2026?` at start_link time; when enabled, diff output is
  bracketed in `\\e[?2026h` and `\\e[?2026l` so the terminal
  composites the whole frame before displaying it. Auto-detection
  via DCS query is deferred to 4.1.
  """

  use GenServer

  @clear_screen "\e[2J\e[3J"
  @cursor_home "\e[H"
  @erase_below "\e[J"
  @sgr_reset_and_clear "\e[m\e[K"
  @sync_on "\e[?2026h"
  @sync_off "\e[?2026l"

  # --- public API ---

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Render a list of lines. Returns the bytes to write.

  An optional `cursor_seq` (e.g. `"\\e[5;3H"`) is appended inside
  the sync block so the cursor move is atomic with the frame update.
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
    # Termux suppresses clear-screen on height-only changes — but we
    # still need to invalidate the previous frame so the diff path
    # notices the new dimensions on the next render.
    suppress? = state.termux? and w == state.width
    new_prev = if suppress?, do: state.previous, else: nil
    {:reply, :ok, %{state | width: w, height: h, previous: new_prev}}
  end

  def handle_call(:full_redraws, _from, state),
    do: {:reply, state.full_redraws, state}

  # --- compute dispatch (multi-head on state shape) ---
  #
  # Full redraw when: first render, or previous frame was longer
  # (need to clear stale rows). Growth is handled by the diff path
  # — new lines simply paint below the previous content.

  defp compute(lines, cursor_seq, %{previous: nil} = state),
    do: full_redraw(lines, cursor_seq, state)

  defp compute(lines, cursor_seq, %{previous: prev} = state)
       when length(lines) < length(prev),
       do: full_redraw(lines, cursor_seq, state)

  defp compute(lines, cursor_seq, state), do: diff(lines, cursor_seq, state)

  # --- full redraw ---

  defp full_redraw(lines, cursor_seq, state) do
    body = [@clear_screen, @cursor_home, render_lines(lines, 0), @erase_below, cursor_seq]
    bytes = IO.iodata_to_binary(wrap_sync(body, state))
    {bytes, %{state | previous: lines, full_redraws: state.full_redraws + 1}}
  end

  # --- diff ---

  defp diff(lines, cursor_seq, state) do
    case find_diff_range(lines, state.previous) do
      {-1, -1} ->
        if cursor_seq == "" do
          {"", %{state | previous: lines}}
        else
          bytes = IO.iodata_to_binary(wrap_sync([cursor_seq], state))
          {bytes, %{state | previous: lines}}
        end

      {first, last} ->
        body = [
          move_to_row(first),
          render_lines(Enum.slice(lines, first..last), first),
          cursor_seq
        ]

        bytes = IO.iodata_to_binary(wrap_sync(body, state))
        {bytes, %{state | previous: lines}}
    end
  end


  # --- output helpers ---

  # Render lines starting at forward-order `start_idx`. Each line
  # is followed by clear-to-eol to wipe leftover bytes from the
  # previous frame's (longer) row. Rows are separated by CRLF so
  # cursor positioning tracks line-by-line.
  defp render_lines([], _idx), do: []

  defp render_lines([line], _idx), do: [line, @sgr_reset_and_clear]

  defp render_lines([line | rest], idx),
    do: [line, @sgr_reset_and_clear, "\r\n" | render_lines(rest, idx + 1)]

  # CSI cursor position is 1-indexed; column 1 for row start.
  defp move_to_row(idx), do: "\e[#{idx + 1};1H"

  defp wrap_sync(body, %{csi_2026?: true}), do: [@sync_on, body, @sync_off]
  defp wrap_sync(body, %{csi_2026?: false}), do: body

  defp termux?, do: System.get_env("TERMUX_VERSION") != nil
end
