defmodule OctoPi.CoderTest do
  use ExUnit.Case, async: true

  describe "supervision tree" do
    test "FileMutex.Registry is started" do
      assert Process.whereis(OctoPi.Coder.FileMutex.Registry)
    end

    test "FileMutex.Supervisor is started" do
      assert Process.whereis(OctoPi.Coder.FileMutex.Supervisor)
    end

    test "SessionStore.Supervisor is started" do
      assert Process.whereis(OctoPi.Coder.SessionStore.Supervisor)
    end
  end
end
