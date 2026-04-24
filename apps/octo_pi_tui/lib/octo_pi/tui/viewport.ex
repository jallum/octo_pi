defmodule OctoPi.TUI.Viewport do
  @moduledoc """
  Pure viewport windowing. Given a list of rendered lines and the
  terminal height, returns the tail that fits — a read-only
  scrollback with no keyboard scrolling for MVP.
  """

  @spec window([String.t()], pos_integer()) :: [String.t()]
  def window(lines, height) when height > 0 do
    len = length(lines)

    cond do
      len == height -> lines
      len > height -> Enum.drop(lines, len - height)
      true -> List.duplicate("", height - len) ++ lines
    end
  end
end
