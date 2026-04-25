defmodule OctoPi.TUI.Components.Text do
  @moduledoc """
  Static text component. Splits `content` on newlines and
  truncates each line to `width` characters (ignoring ANSI escape
  codes in the byte-count). No word wrap, no handle_key — static
  content only.

  Full ANSI-aware word wrapping lives in a later component /
  helper; MVP Text is intentionally minimal.
  """

  @behaviour OctoPi.TUI.Component

  @enforce_keys [:content]
  defstruct content: ""

  @type t :: %__MODULE__{content: String.t()}

  @impl true
  def render(%__MODULE__{content: content}, width) do
    content
    |> String.replace("\t", "   ")
    |> String.split("\n")
    |> Enum.map(&truncate(&1, width))
  end

  # Keep lines that already fit as-is (fast path).
  defp truncate(line, width) when byte_size(line) <= width, do: line

  # Grapheme-based slice for everything else. `String.slice/3`
  # handles invalid UTF-8 by falling back to bytes, so we don't
  # need a separate head for that case.
  defp truncate(line, width), do: String.slice(line, 0, width)
end
