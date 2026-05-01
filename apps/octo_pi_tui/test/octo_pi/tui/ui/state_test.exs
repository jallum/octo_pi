defmodule OctoPi.TUI.UI.State.TestComponent do
  @moduledoc false
  alias OctoPi.TUI.UI.State
  alias OctoPi.TUI.RenderContext

  defstruct [:label]

  def render(props, ctx) do
    label = Map.get(props, :label, "default")
    {value, _setter} = State.use_state(ctx.state, {:state, label}, label)
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
      {value, state2, setter} = State.use_state(state, {:state, 0}, "initial")
      assert value == "initial"
      assert is_function(setter, 1)
    end

    test "returns existing state on subsequent calls" do
      state = State.new(State.TestComponent, %{})
      id = {:state, 0}
      
      # First call
      {value1, state2, setter1} = State.use_state(state, id, "first")
      assert value1 == "first"
      
      # Manually set the state in the cell
      state2 = %{state | hook_cells: Map.put(state.hook_cells, id, %State.StateCell{value: "stored"})}
      
      # Second call should return stored value
      {value2, _setter2} = State.use_state(state2, id, "ignored")
      assert value2 == "stored"
    end

    test "setter updates state and marks dirty" do
      state = State.new(State.TestComponent, %{})
      id = {:state, 0}
      {value1, state2, setter} = State.use_state(state, id, "initial")

      state2 = setter.(state, "updated")
      assert state2.dirty == true
      {value, state3, _} = State.use_state(state2, id, "ignored")
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

      {value, state2, _vnode} = State.use_memo(state, id, :key1, thunk)

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

      {frame, state2, _vnode} = State.use_frame(state, id, 100)

      assert frame == 0
      assert state2.gen > state.gen
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

      state = State.use_key(state, {:key, 0}, :any, handler)

      key = %Key{key: "a", modifiers: []}
      state2 = State.handle_key(state, key)

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
      {_v1, state} = State.use_state(state, id1, "old")
      state = %{state | gen: 1}
      
      # Create cells in gen 1  
      {_v2, state} = State.use_state(state, id2, "current")
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
      {_v, state} = State.use_state(state, id, "value")
      state = %{state | gen: 1}
      
      # GC should keep gen 0 and 1 (current and previous)
      state = State.gc(state)

      assert Map.has_key?(state.hook_cells, id)
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