defmodule OctoPi.AITest do
  use ExUnit.Case
  doctest OctoPi.AI

  test "greets the world" do
    assert OctoPi.AI.hello() == :world
  end
end
