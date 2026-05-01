defmodule OctoPi.TUI.UI.State do
  @moduledoc """
  Pure-functional reconciler state for the React-style component system.
  """

  alias OctoPi.TUI.{RenderContext, Key}

  defstruct [
    :root_component,
    :props,
    :render_ctx,
    :dirty,
    :last_paint_at_ms,
    :dirty_since_ms,
    :max_staleness_ms,
    :frame,
    :hook_cells,
    :gen
  ]

  @type t :: %__MODULE__{
          root_component: module(),
          props: map(),
          render_ctx: RenderContext.t() | nil,
          dirty: boolean(),
          last_paint_at_ms: non_neg_integer() | nil,
          dirty_since_ms: non_neg_integer() | nil,
          max_staleness_ms: non_neg_integer(),
          frame: non_neg_integer(),
          hook_cells: %{binary() => term()},
          gen: non_neg_integer()
        }

  ## Hook cell definitions

  defmodule StateCell do
    @moduledoc "use_state cell"
    defstruct [:value, :gen]
  end

  defmodule MemoCell do
    @moduledoc "use_memo cell"
    defstruct [:key, :thunk, :value, :gen]
  end

  defmodule FrameCell do
    @moduledoc "use_frame cell"
    defstruct [:deadline_ms, :frame_index, gen: 0]
  end

  defmodule KeyCell do
    @moduledoc "use_key cell"
    defstruct [:spec, :handler, gen: 0]
  end

  defmodule EffectCell do
    @moduledoc "use_effect cell"
    defstruct [:key, :mount, :cleanup, gen: 0]
  end

  @type cell_id :: {any(), non_neg_integer()}

  defmodule RenderCtxWithHooks do
    @moduledoc "Render context extended with UI state for hook access"
    defstruct [:width, :state]
  end

  ## Public API

  @spec new(module(), map()) :: t()
  def new(root_component, props) when is_atom(root_component) and is_map(props) do
    now = System.monotonic_time(:millisecond)

    %__MODULE__{
      root_component: root_component,
      props: props,
      render_ctx: nil,
      dirty: true,
      last_paint_at_ms: nil,
      dirty_since_ms: now,
      max_staleness_ms: 16,
      frame: 0,
      hook_cells: %{},
      gen: 0
    }
  end

  @spec mark_dirty(t(), non_neg_integer()) :: t()
  def mark_dirty(%__MODULE__{} = state, now_ms) do
    %{state | dirty: true, dirty_since_ms: state.dirty_since_ms || now_ms}
  end

  @spec dirty?(t()) :: boolean()
  def dirty?(%__MODULE__{dirty: dirty}), do: dirty

  @spec tick(t(), non_neg_integer()) :: t()
  def tick(%__MODULE__{frame: frame} = state, _now_ms) do
    %{state | frame: frame + 1}
  end

  @spec next_wait_ms(t()) :: non_neg_integer() | :infinity
  def next_wait_ms(%__MODULE__{} = state) do
    now = System.monotonic_time(:millisecond)
    min_deadline = compute_min_deadline(state, now)

    if state.dirty_since_ms do
      max_deadline = state.dirty_since_ms + state.max_staleness_ms
      effective_deadline = min(min_deadline, max_deadline)
      max(0, effective_deadline - now)
    else
      max(0, min_deadline - now)
    end
  end

  defp compute_min_deadline(%__MODULE__{hook_cells: cells}, now) do
    cells
    |> Map.values()
    |> Enum.reduce(now + 16, fn cell, acc ->
      case cell do
        %FrameCell{deadline_ms: deadline} when is_integer(deadline) ->
          min(acc, deadline)

        _ ->
          acc
      end
    end)
  end

  @spec handle_key(t(), Key.t()) :: t()
  def handle_key(%__MODULE__{hook_cells: cells} = state, key) do
    cells
    |> Enum.reduce(state, fn {id, cell}, acc_state ->
      case cell do
        %KeyCell{spec: :any, handler: handler} ->
          handler.(acc_state, key, id)

        %KeyCell{spec: spec, handler: handler} when spec == key ->
          handler.(acc_state, key, id)

        _ ->
          acc_state
      end
    end)
  end

  @spec handle_event(t(), term()) :: t()
  def handle_event(%__MODULE__{} = state, _event), do: state

  @spec paint(t(), RenderContext.t()) :: {t(), iodata(), nil | {non_neg_integer(), non_neg_integer()}}
  def paint(%__MODULE__{root_component: component} = state, render_ctx) do
    now = System.monotonic_time(:millisecond)

    state = %{state | gen: state.gen + 1, render_ctx: render_ctx}

    # Build render context with state for hooks
    ctx = %RenderCtxWithHooks{
      width: render_ctx.width,
      state: state
    }

    # Call component render (outputs VDOM tree)
    vnode = component.render(state.props, ctx)

    # Paint VDOM to iodata
    {iodata, cursor} = OctoPi.TUI.VDOM.LineBuf.finalize(
      OctoPi.TUI.VDOM.Paint.paint(vnode, OctoPi.TUI.VDOM.LineBuf.new(), render_ctx)
    )

    state = %{state | dirty: false, dirty_since_ms: nil, last_paint_at_ms: now, hook_cells: ctx.state.hook_cells}

    cursor_seq = format_cursor(cursor)

    {state, iodata, cursor_seq}
  end

  # Format cursor position into ANSI sequence
  defp format_cursor(nil), do: ""
  defp format_cursor({row, col, style}) do
    style_seq = case style do
      :bar -> "\e[5 q"
      :block -> "\e[1 q"
      :underline -> "\e[3 q"
      _ -> "\e[5 q"  # default bar
    end

    # cursor is 1-based in ANSI
    "\e[?25h#{style_seq}\e[#{row + 1};#{col + 1}H"
  end

  @spec use_state(t(), cell_id(), term() | (() -> term())) :: {{term(), (term() -> t())}, t()}
  def use_state(%__MODULE__{hook_cells: cells, gen: gen} = state, id, init) do
    case cells do
      %{^id => %StateCell{value: value}} ->
        setter = &update_state_cell(&1, id, &2)
        {{value, setter}, state}

      _ ->
        value = if is_function(init, 0), do: init.(), else: init
        cell = %StateCell{value: value, gen: gen}
        cells = Map.put(cells, id, cell)
        setter = &update_state_cell(&1, id, &2)
        {{value, setter}, %{state | hook_cells: cells}}
    end
  end

  defp update_state_cell(%__MODULE__{hook_cells: cells} = state, id, new_value) do
    now = System.monotonic_time(:millisecond)

    case cells do
      %{^id => %StateCell{} = cell} ->
        new_cell = %{cell | value: new_value}
        cells = Map.put(cells, id, new_cell)
        mark_dirty(%{state | hook_cells: cells}, now)

      _ ->
        cell = %StateCell{value: new_value}
        cells = Map.put(cells, id, cell)
        mark_dirty(%{state | hook_cells: cells}, now)
    end
  end

  @spec use_memo(t(), cell_id(), term(), (() -> term())) :: {term(), t()}
  def use_memo(%__MODULE__{hook_cells: cells, gen: gen} = state, id, key, thunk) do
    case cells do
      %{^id => %MemoCell{key: ^key, gen: ^gen} = cell} ->
        {cell.value, state}

      %{^id => %MemoCell{key: ^key} = cell} when cell.gen == gen - 1 ->
        value = thunk.()
        new_cell = %{cell | key: key, value: value, gen: gen}
        cells = Map.put(cells, id, new_cell)

        {value, %{state | hook_cells: cells}}

      _ ->
        value = thunk.()
        cell = %MemoCell{key: key, value: value, gen: gen}
        cells = Map.put(cells, id, cell)

        {value, %{state | hook_cells: cells}}
    end
  end

  @spec use_frame(t(), cell_id(), non_neg_integer()) :: {non_neg_integer(), t()}
  def use_frame(%__MODULE__{hook_cells: cells, frame: frame, gen: gen} = state, id, ms) do
    now = System.monotonic_time(:millisecond)
    deadline = now + ms

    case cells do
      %{^id => %FrameCell{gen: ^gen} = cell} ->
        if cell.deadline_ms != deadline do
          new_cell = %{cell | deadline_ms: deadline}
          cells = Map.put(cells, id, new_cell)
          {frame, %{state | hook_cells: cells}}
        else
          {frame, state}
        end

      _ ->
        cell = %FrameCell{deadline_ms: deadline, frame_index: frame, gen: gen}
        cells = Map.put(cells, id, cell)
        {frame, %{state | hook_cells: cells}}
    end
  end

  @spec use_key(t(), cell_id(), Key.t() | :any, (t(), Key.t(), cell_id() -> t())) :: t()
  def use_key(%__MODULE__{hook_cells: cells, gen: gen} = state, id, key_spec, handler) do
    cell = %KeyCell{spec: key_spec, handler: handler, gen: gen}
    cells = Map.put(cells, id, cell)
    %{state | hook_cells: cells}
  end

  @spec use_effect(t(), cell_id(), term(), (() -> term() | nil), [term()]) :: t()
  def use_effect(%__MODULE__{hook_cells: cells, gen: gen} = state, id, key, effect_fn, deps) do
    deps_list = if is_list(deps), do: deps, else: [deps]
    
    case cells do
      %{^id => %EffectCell{key: existing_key, cleanup: existing_cleanup} = cell} ->
        # Cell exists - check if deps changed
        if existing_key == key do
          # Deps unchanged - just refresh gen
          new_cell = %{cell | gen: gen}
          cells = Map.put(cells, id, new_cell)
          %{state | hook_cells: cells}
        else
          # Deps changed - run cleanup then effect
          if is_function(existing_cleanup), do: existing_cleanup.()
          
          cleanup = effect_fn.()
          new_cell = %EffectCell{key: key, mount: effect_fn, cleanup: cleanup, gen: gen}
          cells = Map.put(cells, id, new_cell)
          %{state | hook_cells: cells}
        end
        
      _ ->
        # New cell - run effect and store cleanup
        cleanup = effect_fn.()
        cell = %EffectCell{key: key, mount: effect_fn, cleanup: cleanup, gen: gen}
        cells = Map.put(cells, id, cell)
        %{state | hook_cells: cells}
    end
  end

  @spec gc(t()) :: t()
  def gc(%__MODULE__{hook_cells: cells, gen: gen} = state) do
    {cells_to_keep, cells_to_drop} = 
      cells
      |> Enum.split_with(fn {_id, cell} ->
        cell.gen >= gen - 1
      end)
    
    # Call cleanup on dropped cells
    cells_to_drop = Map.drop(cells, Enum.map(cells_to_keep, fn {id, _} -> id end))
    
    Enum.each(cells_to_drop, fn {_id, cell} ->
      case cell do
        %EffectCell{cleanup: cleanup} when is_function(cleanup) ->
          cleanup.()
        _ ->
          :ok
      end
    end)
    
    %{state | hook_cells: Map.new(cells_to_keep)}
  end
end