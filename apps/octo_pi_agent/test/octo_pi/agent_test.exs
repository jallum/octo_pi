defmodule OctoPi.AgentTest do
  use ExUnit.Case
  doctest OctoPi.Agent

  test "greets the world" do
    assert OctoPi.Agent.hello() == :world
  end
end
