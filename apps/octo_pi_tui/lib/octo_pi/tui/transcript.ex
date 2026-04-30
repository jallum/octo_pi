defmodule OctoPi.TUI.Transcript do
  @moduledoc """
  Stable-cell render state for a transcript of streamed entries.

  An "entry" is opaque — text, thinking, tool call, anything. Each
  entry has a stable `id`, a piece of canonical `data`, and a
  `Renderer`-behaviour module that turns a state + theme + width
  into iodata.

  Order is append-only with one mutable slot at a time; entries
  never move once added. The struct is shaped for O(1) append and
  O(pending) per-entry render — finalized entries hit a cache.

  Internal layout:

      %Transcript{
        order:     [id, ...],          # newest-head; append by [id | order]
        data:      %{id => entry},     # current value for every entry
        modules:   %{id => mod},       # renderer module per entry
        renderers: %{id => state},     # only present while pending render
        finalized: MapSet of ids that have been finalized
        rendered:  %{id => iodata()}   # cached output per entry
      }

  Lifecycle: `append` → many `update` → `finalize`. Each transition
  feeds the renderer; `render/3` materializes pending state into
  `rendered` and drops finalized renderers from `renderers`. After
  finalize + one render, that entry is fully cached — subsequent
  renders emit it verbatim.
  """

  defmodule Renderer do
    @moduledoc """
    Behaviour for entry-level renderers. Transcript dispatches every
    chunk through these callbacks; it knows nothing about entry
    kinds.

    `new/1` must produce a state fully derivable from `entry` — the
    Transcript replays it on `resize/3` without any history.
    """

    @callback new(entry :: term()) :: state :: term()
    @callback put(state :: term(), entry :: term()) :: state :: term()
    @callback finalize(state :: term(), entry :: term()) :: state :: term()
    @callback to_iolist(state :: term(), theme :: term(), width :: pos_integer()) :: iodata()
  end

  @type id :: term()
  @type entry :: term()
  @type t :: %__MODULE__{
          order: [id()],
          data: %{id() => entry()},
          modules: %{id() => module()},
          renderers: %{id() => term()},
          finalized: MapSet.t(),
          rendered: %{id() => iodata()}
        }

  defstruct order: [],
            data: %{},
            modules: %{},
            renderers: %{},
            finalized: MapSet.new(),
            rendered: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc "Append a new entry. `mod` must implement `Renderer`."
  @spec append(t(), id(), entry(), module()) :: t()
  def append(%__MODULE__{} = t, id, entry, mod) when is_atom(mod) do
    %{
      t
      | order: [id | t.order],
        data: Map.put(t.data, id, entry),
        modules: Map.put(t.modules, id, mod),
        renderers: Map.put(t.renderers, id, mod.new(entry))
    }
  end

  @doc "Update an existing entry mid-stream. Renderer must still be live."
  @spec update(t(), id(), entry()) :: t()
  def update(%__MODULE__{} = t, id, entry) do
    mod = Map.fetch!(t.modules, id)
    state = mod.put(Map.fetch!(t.renderers, id), entry)
    %{t | data: Map.put(t.data, id, entry), renderers: Map.put(t.renderers, id, state)}
  end

  @doc """
  Finalize an entry. The next `render/3` will materialize its iodata
  into `rendered` and drop the renderer.
  """
  @spec finalize(t(), id(), entry()) :: t()
  def finalize(%__MODULE__{} = t, id, entry) do
    mod = Map.fetch!(t.modules, id)
    state = mod.finalize(Map.fetch!(t.renderers, id), entry)

    %{
      t
      | data: Map.put(t.data, id, entry),
        renderers: Map.put(t.renderers, id, state),
        finalized: MapSet.put(t.finalized, id)
    }
  end

  @doc """
  Render the transcript at `theme` × `width`. Returns the emitted
  iodata (oldest-first) and the updated transcript: pending renderers
  are folded into `rendered`, and finalized renderers are dropped.

  Subsequent calls without state changes emit purely from `rendered`.
  """
  @spec render(t(), term(), pos_integer()) :: {iodata(), t()}
  def render(%__MODULE__{} = t, theme, width) do
    {rendered, renderers} =
      Enum.reduce(t.order, {t.rendered, t.renderers}, fn id, {rmap, rrmap} ->
        case Map.fetch(rrmap, id) do
          {:ok, state} ->
            mod = Map.fetch!(t.modules, id)
            io = mod.to_iolist(state, theme, width)
            rmap2 = Map.put(rmap, id, io)
            rrmap2 = if MapSet.member?(t.finalized, id), do: Map.delete(rrmap, id), else: rrmap
            {rmap2, rrmap2}

          :error ->
            {rmap, rrmap}
        end
      end)

    iolist =
      t.order
      |> Enum.reverse()
      |> Enum.map(&Map.get(rendered, &1, []))

    {iolist, %{t | rendered: rendered, renderers: renderers}}
  end

  @doc """
  Resize / re-theme: rebuild every entry's renderer from its `data`
  and re-render once. `Renderer.new/1` must therefore be a complete
  snapshot for the entry — Transcript holds no replay history.
  """
  @spec resize(t(), term(), pos_integer()) :: t()
  def resize(%__MODULE__{} = t, theme, width) do
    renderers =
      Enum.reduce(t.data, %{}, fn {id, entry}, acc ->
        mod = Map.fetch!(t.modules, id)
        state = mod.new(entry)
        state = if MapSet.member?(t.finalized, id), do: mod.finalize(state, entry), else: state
        Map.put(acc, id, state)
      end)

    {_, t2} = render(%{t | renderers: renderers, rendered: %{}}, theme, width)
    t2
  end
end
