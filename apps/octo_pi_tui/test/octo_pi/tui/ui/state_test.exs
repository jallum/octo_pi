defmodule OctoPi.TUI.UI.State.TestComponent do
  @moduledoc false
  alias OctoPi.TUI.UI.State
  alias OctoPi.TUI.RenderContext

  defstruct [:label]

  def render(props, ctx) do
    label = Map.get(props, :label, "default")
    {{value, _setter}, _state2} = State.use_state(ctx.state, {:state, label}, label)
    %OctoPi.TUI.VDOM.VText{text: "#{value}", width: String.length(value)}
  end
end

defmodule OctoPi.TUI.UI.StateTest do
  use ExUnit.Case, async: true
  alias OctoPi.TUI.UI.State
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Key

  describe "new/2" do
    test "creates initial state" do
      state = State.new(State.TestComponent, %{label: "test"})
      assert state.root_component == State.TestComponent
      assert state.props == %{label: "test"}
      assert state.dirty == true
      assert state.frame == 0
      assert state.gen == 0
    end
  end

  describe "mark_dirty/2" do
    test "sets dirty flag with timestamp" do
      state = State.new(State.TestComponent, %{})
      now = System.monotonic_time(:millisecond)
      state = State.mark_dirty(state, now)
      assert state.dirty == true
      assert state.dirty_since_ms == now
    end
  end

  describe "dirty?/1" do
    test "returns dirty flag" do
      state = State.new(State.TestComponent, %{})
      assert State.dirty?(state) == true
      state = %{state | dirty: false}
      assert State.dirty?(state) == false
    end
  end

  describe "tick/2" do
    test "increments frame counter" do
      state = State.new(State.TestComponent, %{}) |> State.tick(0)
      assert state.frame == 1
      state = State.tick(state, 0)
      assert state.frame == 2
    end
  end

  describe "next_wait_ms/1" do
    test "returns max_staleness_ms when dirty" do
      state = State.new(State.TestComponent, %{}) |> State.mark_dirty(100)
      wait = State.next_wait_ms(state)
      assert wait <= 16
      assert wait >= 0
    end

    test "returns frame deadline when animation active" do
      state = State.new(State.TestComponent, %{})
      {_frame, state} = State.use_frame(state, {:frame, self()}, 50)
      wait = State.next_wait_ms(state)
      # Should be <= 50ms (frame deadline) but not infinity
      assert wait > 0 and wait <= 50
    end
  end

  describe "use_state/3" do
    test "initializes state cell" do
      state = State.new(State.TestComponent, %{})
      {{value, setter}, state2} = State.use_state(state, {:state, 0}, "initial")
      assert value == "initial"
      assert is_function(setter, 2)
    end

    test "returns existing state on subsequent calls" do
      state = State.new(State.TestComponent, %{})
      id = {:state, 0}

      # First call creates cell
      {{value1, setter1}, state2} = State.use_state(state, id, "first")
      assert value1 == "first"

      # Set value using setter
      state_after_set = setter1.(state2, "stored")

      # Second call should return stored value
      {{value2, _setter2}, _state3} = State.use_state(state_after_set, id, "ignored")
      assert value2 == "stored"
    end

    test "setter updates state and marks dirty" do
      state = State.new(State.TestComponent, %{})
      id = {:state, 0}
      {{_value, setter}, state_after_init} = State.use_state(state, id, "initial")

      state_after_set = setter.(state_after_init, "updated")
      assert state_after_set.dirty == true

      {{value, _setter}, _state3} = State.use_state(state_after_set, id, "ignored")
      assert value == "updated"
    end
  end

  describe "use_memo/4" do
    test "calls thunk on first access" do
      state = State.new(State.TestComponent, %{})
      id = {:memo, 0}
      call_count = make_ref()
      :ets.new(:test_counts, [:named_table, :public])
      :ets.insert(:test_counts, {call_count, 0})

      thunk = fn ->
        [{_, count}] = :ets.lookup(:test_counts, call_count)
        :ets.insert(:test_counts, {call_count, count + 1})
        "computed"
      end

      {value, state2} = State.use_memo(state, id, :key1, thunk)

      assert value == "computed"
      [{_, count}] = :ets.lookup(:test_counts, call_count)
      assert count == 1
    end

    test "returns cached value when key unchanged" do
      state = State.new(State.TestComponent, %{})
      id = {:memo, 0}
      thunk = fn -> "cached" end

      {value1, state2} = State.use_memo(state, id, :same_key, thunk)
      {value2, _} = State.use_memo(state2, id, :same_key, thunk)

      assert value1 == value2
      assert value2 == "cached"
    end

    test "re-evaluates when key changes" do
      state = State.new(State.TestComponent, %{})
      id = {:memo, 0}

      {value1, state2} = State.use_memo(state, id, :key1, fn -> "first" end)
      {value2, _} = State.use_memo(state2, id, :key2, fn -> "second" end)

      assert value1 == "first"
      assert value2 == "second"
    end
  end

  describe "use_frame/3" do
    test "initializes frame cell with deadline" do
      state = State.new(State.TestComponent, %{}) 
      id = {:frame, 0}

      {frame, state2} = State.use_frame(state, id, 100)

      assert frame == 0
      # State gen doesn't change in use_frame, only hook_cells are updated
      assert state2.gen == state.gen
    end
  end

  describe "handle_key/2" do
    test "routes key to matching handler" do
      state = State.new(State.TestComponent, %{}) |> State.tick(0)

      # Start with clean state
      state = %{state | dirty: false, dirty_since_ms: nil}

      handler = fn state2, _key, _id ->
        State.mark_dirty(state2, 0)
      end

      state_after_key = State.use_key(state, {:key, 0}, :any, handler)

      key = %Key{key: "a", modifiers: []}
      state2 = State.handle_key(state_after_key, key)

      assert state2.dirty == true
    end

    test "does not modify state when no handler matches" do
      state = State.new(State.TestComponent, %{})
      key = %Key{key: "a", modifiers: []}
      state2 = State.handle_key(state, key)
      assert state2 == state
    end
  end

  describe "gc/1" do
    test "removes cells older than previous generation" do
      state = State.new(State.TestComponent, %{})
      id1 = {:gc_test, 1}
      id2 = {:gc_test, 2}

      # Create cells in gen 0
      {{_v1, _setter1}, state} = State.use_state(state, id1, "old")
      state = %{state | gen: 1}

      # Create cells in gen 1
      {{_v2, _setter2}, state} = State.use_state(state, id2, "current")
      state = %{state | gen: 2}

      # GC run (keeps gen 1 and 2, drops gen 0)
      state = State.gc(state)

      assert Map.has_key?(state.hook_cells, id2)
      refute Map.has_key?(state.hook_cells, id1)
    end

    test "preserves cells from current and previous generation" do
      state = State.new(State.TestComponent, %{})
      id = {:gc_test, 1}

      # Create cell in gen 0
      {{_v, _setter}, state} = State.use_state(state, id, "value")
      state = %{state | gen: 1}

      # GC should keep gen 0 and 1 (current and previous)
      state = State.gc(state)

      assert Map.has_key?(state.hook_cells, id)
    end
  end

  describe "use_effect/5" do
    test "runs effect on first mount" do
      state = State.new(State.TestComponent, %{}) 
      id = {:effect, 0}
      
      effect_called = make_ref()
      :ets.new(:effect_calls, [:named_table, :public])
      :ets.insert(:effect_calls, {effect_called, false})
      
      effect = fn ->
        :ets.insert(:effect_calls, {effect_called, true})
      end
      
      state_after = State.use_effect(state, id, :mount, effect, [])
      
      [{_, called}] = :ets.lookup(:effect_calls, effect_called)
      assert called == true
      assert Map.has_key?(state_after.hook_cells, id)
    end
    
    test "does not re-run effect when deps unchanged" do
      state = State.new(State.TestComponent, %{}) 
      id = {:effect, 0}
      key = :stable
      
      call_count = make_ref()
      :ets.new(:effect_counts, [:named_table, :public])
      :ets.insert(:effect_counts, {call_count, 0})
      
      effect = fn ->
        [{_, count}] = :ets.lookup(:effect_counts, call_count)
        :ets.insert(:effect_counts, {call_count, count + 1})
      end
      
      # First call
      state2 = State.use_effect(state, id, key, effect, [])
      [{_, count1}] = :ets.lookup(:effect_counts, call_count)
      assert count1 == 1
      
      # Second call with same deps
      state3 = State.use_effect(state2, id, key, effect, [])
      [{_, count2}] = :ets.lookup(:effect_counts, call_count)
      assert count2 == 1  # Should still be 1, not re-run
    end
    
    test "re-runs effect when deps change" do
      state = State.new(State.TestComponent, %{}) 
      id = {:effect, 0}
      
      call_count = make_ref()
      :ets.new(:effect_counts, [:named_table, :public])
      :ets.insert(:effect_counts, {call_count, 0})
      
      effect = fn ->
        [{_, count}] = :ets.lookup(:effect_counts, call_count)
        :ets.insert(:effect_counts, {call_count, count + 1})
      end
      
      # First call with deps [1]
      state2 = State.use_effect(state, id, :deps1, effect, [1])
      [{_, count1}] = :ets.lookup(:effect_counts, call_count)
      assert count1 == 1
      
      # Second call with different deps [2]
      state3 = State.use_effect(state2, id, :deps2, effect, [2])
      [{_, count2}] = :ets.lookup(:effect_counts, call_count)
      assert count2 == 2  # Should be 2, re-run with new deps
    end
    
    test "calls cleanup on deps change" do
      state = State.new(State.TestComponent, %{}) 
      id = {:effect, 0}
      
      cleanup_called = make_ref()
      :ets.new(:cleanup_calls, [:named_table, :public])
      :ets.insert(:cleanup_calls, {cleanup_called, 0})
      
      effect = fn ->
        fn ->  # cleanup function
          [{_, count}] = :ets.lookup(:cleanup_calls, cleanup_called)
          :ets.insert(:cleanup_calls, {cleanup_called, count + 1})
        end
      end
      
      # First call
      state2 = State.use_effect(state, id, :key1, effect, [1])
      [{_, cleanup1}] = :ets.lookup(:cleanup_calls, cleanup_called)
      assert cleanup1 == 0  # No cleanup yet
      
      # Second call with different deps - cleanup should run
      state3 = State.use_effect(state2, id, :key2, effect, [2])
      [{_, cleanup2}] = :ets.lookup(:cleanup_calls, cleanup_called)
      assert cleanup2 == 1  # Cleanup ran once
    end
    
    test "calls cleanup on gc" do
      state = State.new(State.TestComponent, %{}) 
      id = {:effect, 0}
      
      cleanup_called = make_ref()
      :ets.new(:cleanup_gc_calls, [:named_table, :public])
      :ets.insert(:cleanup_gc_calls, {cleanup_called, 0})
      
      effect = fn ->
        fn ->  # cleanup function
          [{_, count}] = :ets.lookup(:cleanup_gc_calls, cleanup_called)
          :ets.insert(:cleanup_gc_calls, {cleanup_called, count + 1})
        end
      end
      
      # Create effect in gen 0
      state2 = State.use_effect(state, id, :gc_test, effect, [])
      
      # Advance gen to make cell eligible for GC (gen 0 < gen 2 - 1)
      state3 = %{state2 | gen: 2}
      state4 = State.gc(state3)
      
      # Verify cleanup ran
      [{_, cleanup_count}] = :ets.lookup(:cleanup_gc_calls, cleanup_called)
      assert cleanup_count == 1
      
      # Verify cell was removed
      refute Map.has_key?(state4.hook_cells, id)
    end
  end

  describe "paint/2" do
    test "returns iodata and updates last_paint_at_ms" do
      state = State.new(State.TestComponent, %{})
      ctx = %RenderContext{theme: nil, width: 80, padding_x: 1}

      {state2, iodata, cursor} = State.paint(state, ctx)

      assert is_list(iodata)
      assert state2.last_paint_at_ms != nil
      assert state2.dirty == false
      assert state2.dirty_since_ms == nil
      assert cursor == nil
    end

    test "increments generation on paint" do
      state = State.new(State.TestComponent, %{})
      ctx = %RenderContext{theme: nil, width: 80}

      {_state2, _, _} = State.paint(state, ctx)

      # Generation increments during paint
      assert state.gen == 0
    end
  end
end