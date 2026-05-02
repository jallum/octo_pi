defmodule OctoPi.TUI.Transcript do
  @moduledoc """
  Stable-cell render state for an append-only transcript.

  Each slot holds:
    * a canonical entry struct that implements
      `OctoPi.TUI.TranscriptEntry` (and optionally
      `OctoPi.TUI.StreamingComponent`),
    * a cache of the lines it last produced,
    * a dirty flag (set by `update`/`finalize`/`invalidate`).

  Render walks the slots in order; for each slot it consults the
  dirty flag. If the slot is clean, it emits the cached lines without
  calling the component. Otherwise it calls
  `data.__struct__.render(data, ctx) -> {data', vnode}`, persists the
  updated struct, and caches the vnode.

  No protocol dispatch (everything goes through `mod.render/2`), no
  ctx field on the struct (ctx is render-time only), no resize/2
  (callers use `invalidate/1` to bust the cache on theme/width
  changes).
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Component
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM

  @type id :: term()
  @type t :: %__MODULE__{
          order: [id()],
          data: %{id() => struct()},
          cache: %{id() => VDOM.t()},
          dirty: term()
        }

  defstruct order: [],
            data: %{},
            cache: %{},
            dirty: MapSet.new()

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Append a new entry. Slot starts dirty so the next render builds
  its lines.
  """
  @spec append(t(), id(), struct()) :: t()
  def append(%__MODULE__{} = t, id, %_{} = entry) do
    %{
      t
      | order: [id | t.order],
        data: Map.put(t.data, id, entry),
        dirty: MapSet.put(t.dirty, id)
    }
  end

  @doc """
  Replace a slot's canonical struct outright. Used when the caller
  has already computed the new state (e.g. bash command completion
  swaps a `BashExecution{status: :running}` for one with
  `:complete`); marks the slot dirty so the next render rebuilds.
  """
  @spec replace(t(), id(), struct()) :: t()
  def replace(%__MODULE__{} = t, id, %_{} = entry) do
    %{t | data: Map.put(t.data, id, entry), dirty: MapSet.put(t.dirty, id)}
  end

  @doc """
  Apply a snapshot delta to a streaming slot. Marks the slot dirty
  so the next render rebuilds. Raises if the slot's module doesn't
  implement `StreamingComponent`.
  """
  @spec update(t(), id(), term()) :: t()
  def update(%__MODULE__{} = t, id, snapshot) do
    entry = Map.fetch!(t.data, id)
    ensure_streaming!(entry)

    entry2 = entry.__struct__.update(entry, snapshot)
    %{t | data: Map.put(t.data, id, entry2), dirty: MapSet.put(t.dirty, id)}
  end

  @doc """
  Seal a streaming slot with its final snapshot. Marks dirty.
  Raises if the slot's module doesn't implement `StreamingComponent`.
  """
  @spec finalize(t(), id(), term()) :: t()
  def finalize(%__MODULE__{} = t, id, snapshot) do
    entry = Map.fetch!(t.data, id)
    ensure_streaming!(entry)

    entry2 = entry.__struct__.finalize(entry, snapshot)
    %{t | data: Map.put(t.data, id, entry2), dirty: MapSet.put(t.dirty, id)}
  end

  @doc """
  Bust every cached entry. Callers (typically Interactive on a
  resize or theme change) call this to force a full re-render.
  """
  @impl Component
  @spec invalidate(t()) :: t()
  def invalidate(%__MODULE__{order: order} = t), do: %{t | dirty: MapSet.new(order)}

  @doc "Whether `id` is present in the transcript."
  @spec has_entry?(t(), id()) :: boolean()
  def has_entry?(%__MODULE__{data: data}, id), do: Map.has_key?(data, id)

  @doc "Fetch the canonical data struct for `id`. Raises if not present."
  @spec fetch_data!(t(), id()) :: struct()
  def fetch_data!(%__MODULE__{data: data}, id), do: Map.fetch!(data, id)

  @doc "Get the canonical data struct for `id`, or `default` if not present."
  @spec get_data(t(), id(), term()) :: struct() | term()
  def get_data(%__MODULE__{data: data}, id, default \\ nil), do: Map.get(data, id, default)

  @doc """
  Render the transcript at `ctx`. Walks slots oldest-first; calls
  `mod.render/2` on dirty slots, reuses `cache` for the rest.

  Returns `{t(), %VFlow{}}` conforming to the `Component` behaviour.
  """
  @impl Component
  @spec render(t(), RenderContext.t()) :: {t(), VDOM.t()}
  def render(%__MODULE__{} = t, %RenderContext{} = ctx) do
    {data2, cache2, slots_rev} =
      t.order
      |> Enum.reverse()
      |> Enum.reduce({t.data, t.cache, []}, fn id, {d_acc, c_acc, s_rev} ->
        render_slot(id, d_acc, c_acc, s_rev, t.dirty, ctx)
      end)

    t = %{t | data: data2, cache: cache2, dirty: MapSet.new()}
    vnode = %VDOM.VFlow{children: slots_rev |> Enum.reverse() |> Enum.map(fn {_, v} -> v end)}
    {t, vnode}
  end

  # ── internals ──────────────────────────────────────────────────

  defp render_slot(id, d_acc, c_acc, s_rev, dirty, ctx) do
    if needs_render?(id, dirty, c_acc) do
      do_render(id, d_acc, c_acc, s_rev, ctx)
    else
      entry = Map.fetch!(d_acc, id)
      {d_acc, c_acc, [{entry, Map.fetch!(c_acc, id)} | s_rev]}
    end
  end

  defp needs_render?(id, dirty, c_acc) do
    not Map.has_key?(c_acc, id) or MapSet.member?(dirty, id)
  end

  defp do_render(id, d_acc, c_acc, s_rev, ctx) do
    %mod{} = entry = Map.fetch!(d_acc, id)
    {entry2, vnode} = mod.render(entry, ctx)

    {
      Map.put(d_acc, id, entry2),
      Map.put(c_acc, id, vnode),
      [{entry2, vnode} | s_rev]
    }
  end

  defp ensure_streaming!(%mod{}) do
    Code.ensure_loaded(mod)

    if not (function_exported?(mod, :update, 2) and function_exported?(mod, :finalize, 2)) do
      raise ArgumentError,
            "#{inspect(mod)} does not implement StreamingComponent (missing update/2 or finalize/2)"
    end
  end
end
