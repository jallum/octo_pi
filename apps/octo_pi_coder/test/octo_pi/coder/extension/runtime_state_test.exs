defmodule OctoPi.Coder.Extension.RuntimeStateTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.RuntimeState

  describe "new/0" do
    test "starts active" do
      state = RuntimeState.new()
      assert state.active?
      assert state.invalidation_message == nil
      assert state.flag_values == %{}
    end
  end

  describe "assert_active!/1" do
    test "returns :ok when active" do
      assert :ok = RuntimeState.assert_active!(RuntimeState.new())
    end

    test "raises when invalidated" do
      state = RuntimeState.invalidate(RuntimeState.new(), "session replaced")

      assert_raise RuntimeError, ~r/stale.*session replaced/, fn ->
        RuntimeState.assert_active!(state)
      end
    end

    test "raises with default message when no reason given" do
      state = RuntimeState.invalidate(RuntimeState.new())

      assert_raise RuntimeError, ~r/stale.*invalidated/, fn ->
        RuntimeState.assert_active!(state)
      end
    end
  end

  describe "invalidate/2" do
    test "marks state inactive" do
      state = RuntimeState.invalidate(RuntimeState.new(), "reload")
      refute state.active?
      assert state.invalidation_message == "reload"
    end
  end

  describe "flag management" do
    test "set and get flag values" do
      state = RuntimeState.new()
      state = RuntimeState.set_flag(state, "verbose", true)
      assert RuntimeState.get_flag(state, "verbose") == true
    end

    test "get returns default for missing flags" do
      state = RuntimeState.new()
      assert RuntimeState.get_flag(state, "missing", :default) == :default
    end

    test "set overwrites existing flag" do
      state = RuntimeState.new()
      state = RuntimeState.set_flag(state, "level", 1)
      state = RuntimeState.set_flag(state, "level", 2)
      assert RuntimeState.get_flag(state, "level") == 2
    end
  end
end
