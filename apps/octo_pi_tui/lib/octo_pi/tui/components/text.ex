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

  alias OctoPi.TUI.WrapAnsi

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

  defp truncate(line, width) do
    if WrapAnsi.visible_width(line) <= width do
      line
    else
      WrapAnsi.truncate_to_width(line, width, "")
    end
  end
end
