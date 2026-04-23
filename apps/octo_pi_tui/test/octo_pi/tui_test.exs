defmodule OctoPi.TUITest do
  use ExUnit.Case
  doctest OctoPi.TUI

  test "greets the world" do
    assert OctoPi.TUI.hello() == :world
  end
end
