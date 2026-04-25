defmodule OctoPi.TUITest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.RawMode

  describe "application boot" do
    test "Events registry is started" do
      assert Process.whereis(OctoPi.TUI.Events)
    end

    test "supervisor is registered" do
      assert Process.whereis(OctoPi.TUI.Supervisor)
    end
  end

  describe "RawMode" do
    # We don't actually flip the test runner's tty here — just
    # verify the wrapper compiles and exports the expected surface.
    # `.2` will test the full Terminal lifecycle with a mock RawMode.

    test "enter/0 and exit/0 are exported" do
      Code.ensure_loaded!(RawMode)
      assert function_exported?(RawMode, :enter, 0)
      assert function_exported?(RawMode, :exit, 0)
    end
  end
end
