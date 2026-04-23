defmodule OctoPi.CoderTest do
  use ExUnit.Case
  doctest OctoPi.Coder

  test "greets the world" do
    assert OctoPi.Coder.hello() == :world
  end
end
