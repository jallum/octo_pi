defmodule OctoPi.TUI.VirtualTerminal do
  @moduledoc """
  Minimal ANSI terminal emulator for render tests.

  Maintains a rows×cols grid of strings. Processes the exact CSI
  sequences our Renderer emits, nothing more:

    - \\e[2J        clear screen
    - \\e[J         erase below (cursor to end of screen)
    - \\e[H         cursor home (1,1)
    - \\e[row;colH  cursor absolute position
    - \\e[2K        erase entire line
    - \\e[K         clear to end of line
    - \\e[?2026h/l  synchronized output (ignored)
    - \\r\\n         carriage return + line feed
    - printable     write at cursor, advance

  The grid starts filled with empty strings. Each row accumulates
  characters written to it. `get_viewport/1` returns the grid as
  a list of trimmed-right row strings.
  """

  @type attrs :: %{italic: boolean(), bold: boolean(), underline: boolean()}

  @type t :: %__MODULE__{
          cols: pos_integer(),
          rows: pos_integer(),
          grid: %{non_neg_integer() => String.t()},
          cursor_row: non_neg_integer(),
          cursor_col: non_neg_integer(),
          sgr: attrs(),
          cell_attrs: %{{non_neg_integer(), non_neg_integer()} => attrs()}
        }

  @initial_sgr %{italic: false, bold: false, underline: false}

  defstruct [
    :cols,
    :rows,
    :grid,
    cursor_row: 0,
    cursor_col: 0,
    sgr: %{italic: false, bold: false, underline: false},
    cell_attrs: %{}
  ]

  @doc "Create a new virtual terminal with the given dimensions."
  @spec new(pos_integer(), pos_integer()) :: t()
  def new(cols, rows) do
    %__MODULE__{
      cols: cols,
      rows: rows,
      grid: blank_grid(rows),
      cursor_row: 0,
      cursor_col: 0
    }
  end

  @doc "Process raw ANSI bytes and return the updated terminal."
  @spec write(t(), binary()) :: t()
  def write(term, <<>>), do: term

  # ESC [ ... sequences
  def write(term, <<"\e[", rest::binary>>), do: parse_csi(term, rest, "")

  # CR+LF
  def write(term, <<"\r\n", rest::binary>>) do
    term
    |> newline()
    |> write(rest)
  end

  # CR alone
  def write(term, <<"\r", rest::binary>>) do
    write(%{term | cursor_col: 0}, rest)
  end

  # LF alone
  def write(term, <<"\n", rest::binary>>) do
    term
    |> newline()
    |> write(rest)
  end

  # Skip other ESC sequences (OSC, etc.) — scan to ST or BEL
  def write(term, <<"\e", _c, rest::binary>>) do
    write(term, skip_esc_seq(rest))
  end

  # Printable character (UTF-8 aware)
  def write(term, data) do
    case String.next_grapheme(data) do
      nil ->
        term

      {grapheme, rest} ->
        term
        |> put_char(grapheme)
        |> write(rest)
    end
  end

  @doc "Return the visible grid as a list of row strings (trailing spaces trimmed)."
  @spec get_viewport(t()) :: [String.t()]
  def get_viewport(%__MODULE__{rows: rows, grid: grid}) do
    Enum.map(0..(rows - 1), fn row ->
      grid
      |> Map.get(row, "")
      |> String.trim_trailing()
    end)
  end

  @doc "Return cursor position as `{row, col}` (0-indexed)."
  @spec get_cursor(t()) :: {non_neg_integer(), non_neg_integer()}
  def get_cursor(%__MODULE__{cursor_row: r, cursor_col: c}), do: {r, c}

  @doc "Return the effective SGR attribute map for the given cell."
  @spec cell_attrs(t(), non_neg_integer(), non_neg_integer()) :: attrs()
  def cell_attrs(%__MODULE__{cell_attrs: ca}, row, col),
    do: Map.get(ca, {row, col}, %{italic: false, bold: false, underline: false})

  @doc "Whether the cell at `{row, col}` was written with italic SGR active."
  @spec cell_italic?(t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def cell_italic?(vt, row, col), do: cell_attrs(vt, row, col).italic

  @doc "Resize the terminal. Clears the grid."
  @spec resize(t(), pos_integer(), pos_integer()) :: t()
  def resize(term, cols, rows) do
    %{
      term
      | cols: cols,
        rows: rows,
        grid: blank_grid(rows),
        cursor_row: 0,
        cursor_col: 0,
        cell_attrs: %{}
    }
  end

  # --- CSI parser ---

  # Accumulate parameter bytes until a final letter
  defp parse_csi(term, <<c, rest::binary>>, params) when c in ?0..?9 or c == ?; do
    parse_csi(term, rest, params <> <<c>>)
  end

  # CSI ? prefix (private mode) — accumulate the ? and continue
  defp parse_csi(term, <<??, rest::binary>>, params) do
    parse_csi(term, rest, params <> "?")
  end

  # Final byte: dispatch
  defp parse_csi(term, <<final, rest::binary>>, params) do
    term
    |> exec_csi(<<final>>, params)
    |> write(rest)
  end

  defp parse_csi(term, <<>>, _params), do: term

  # --- CSI execution ---

  # Clear screen: CSI 2 J
  defp exec_csi(term, "J", "2") do
    %{term | grid: blank_grid(term.rows), cell_attrs: %{}}
  end

  # Erase below: CSI J (or CSI 0 J) — clear from cursor to end of screen
  defp exec_csi(term, "J", params) when params in ["", "0"] do
    row_str = Map.get(term.grid, term.cursor_row, "")
    truncated = slice_to_col(row_str, term.cursor_col)
    grid = Map.put(term.grid, term.cursor_row, truncated)

    grid =
      Enum.reduce((term.cursor_row + 1)..(term.rows - 1)//1, grid, fn r, acc ->
        Map.put(acc, r, "")
      end)

    %{term | grid: grid}
  end

  # Cursor home: CSI H (no params)
  defp exec_csi(term, "H", "") do
    %{term | cursor_row: 0, cursor_col: 0}
  end

  # Cursor position: CSI row;col H (1-indexed in ANSI)
  defp exec_csi(term, "H", params) do
    case String.split(params, ";") do
      [row_s, col_s] ->
        row = max(String.to_integer(row_s) - 1, 0)
        col = max(String.to_integer(col_s) - 1, 0)
        %{term | cursor_row: min(row, term.rows - 1), cursor_col: min(col, term.cols - 1)}

      [row_s] ->
        row = max(String.to_integer(row_s) - 1, 0)
        %{term | cursor_row: min(row, term.rows - 1), cursor_col: 0}

      _ ->
        term
    end
  end

  # Erase entire line: CSI 2 K
  defp exec_csi(term, "K", "2") do
    %{term | grid: Map.put(term.grid, term.cursor_row, "")}
  end

  # Clear to end of line: CSI K (or CSI 0 K)
  defp exec_csi(term, "K", params) when params in ["", "0"] do
    row_str = Map.get(term.grid, term.cursor_row, "")
    # Keep only chars up to cursor_col
    truncated = slice_to_col(row_str, term.cursor_col)
    %{term | grid: Map.put(term.grid, term.cursor_row, truncated)}
  end

  # SGR: CSI n (;n)* m — update attribute state
  defp exec_csi(term, "m", params) do
    %{term | sgr: apply_sgr(term.sgr, params)}
  end

  # Synchronized output — ignore
  defp exec_csi(term, "h", "?" <> _), do: term
  defp exec_csi(term, "l", "?" <> _), do: term

  # Cursor up: CSI n A
  defp exec_csi(term, "A", params) do
    n = parse_int(params, 1)
    %{term | cursor_row: max(term.cursor_row - n, 0)}
  end

  # Cursor down: CSI n B
  defp exec_csi(term, "B", params) do
    n = parse_int(params, 1)
    %{term | cursor_row: min(term.cursor_row + n, term.rows - 1)}
  end

  # Unknown CSI — ignore
  defp exec_csi(term, _final, _params), do: term

  # --- grid operations ---

  defp put_char(%{cursor_col: col, cols: cols} = term, _char) when col >= cols do
    term
  end

  defp put_char(term, char) do
    row_str = Map.get(term.grid, term.cursor_row, "")
    new_row = replace_at_col(row_str, term.cursor_col, char)
    cell_attrs = Map.put(term.cell_attrs, {term.cursor_row, term.cursor_col}, term.sgr)

    %{
      term
      | grid: Map.put(term.grid, term.cursor_row, new_row),
        cursor_col: term.cursor_col + 1,
        cell_attrs: cell_attrs
    }
  end

  defp apply_sgr(_sgr, "") do
    # CSI m with no params is equivalent to CSI 0 m (reset all).
    @initial_sgr
  end

  defp apply_sgr(sgr, params) do
    params
    |> String.split(";")
    |> Enum.map(&parse_int(&1, 0))
    |> Enum.reduce(sgr, &apply_sgr_code/2)
  end

  defp apply_sgr_code(0, _sgr), do: @initial_sgr
  defp apply_sgr_code(1, sgr), do: %{sgr | bold: true}
  defp apply_sgr_code(3, sgr), do: %{sgr | italic: true}
  defp apply_sgr_code(4, sgr), do: %{sgr | underline: true}
  defp apply_sgr_code(22, sgr), do: %{sgr | bold: false}
  defp apply_sgr_code(23, sgr), do: %{sgr | italic: false}
  defp apply_sgr_code(24, sgr), do: %{sgr | underline: false}
  defp apply_sgr_code(_other, sgr), do: sgr

  defp newline(%{cursor_row: row, rows: rows} = term) do
    new_row = row + 1

    if new_row >= rows do
      # Scroll: shift all rows up by 1, clear bottom row
      new_grid =
        1..(rows - 1)
        |> Enum.reduce(%{}, fn r, acc ->
          Map.put(acc, r - 1, Map.get(term.grid, r, ""))
        end)
        |> Map.put(rows - 1, "")

      %{term | grid: new_grid, cursor_col: 0}
    else
      %{term | cursor_row: new_row, cursor_col: 0}
    end
  end

  defp blank_grid(rows) do
    Map.new(0..(rows - 1), fn r -> {r, ""} end)
  end

  # Pad row_str to at least `col` characters, then replace char at `col`
  defp replace_at_col(row_str, col, char) do
    graphemes = String.graphemes(row_str)
    len = length(graphemes)

    padded =
      if len <= col do
        graphemes ++ List.duplicate(" ", col - len + 1)
      else
        graphemes
      end

    padded
    |> List.replace_at(col, char)
    |> Enum.join()
  end

  # Truncate a row string to `col` graphemes
  defp slice_to_col(row_str, col) do
    row_str
    |> String.graphemes()
    |> Enum.take(col)
    |> Enum.join()
  end

  defp parse_int("", default), do: default
  defp parse_int(s, _default), do: String.to_integer(s)

  defp skip_esc_seq(<<"\a", rest::binary>>), do: rest
  defp skip_esc_seq(<<"\e\\", rest::binary>>), do: rest
  defp skip_esc_seq(<<_, rest::binary>>), do: skip_esc_seq(rest)
  defp skip_esc_seq(<<>>), do: <<>>
end
