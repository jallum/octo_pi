defmodule OctoPi.TUI.Transcript do
  @moduledoc """
  Stable-cell render state for an append-only transcript.

  An "entry" is opaque — text, thinking, tool call, anything. Each
  entry has a stable `id`, a piece of canonical `data`, and a
  `Renderer`-behaviour module that turns its state into iodata.

  A render context (`ctx`) — an opaque caller-defined map — is held
  on the struct and threaded into `Renderer.new/2`. Concretely
  callers pass `%{theme: ..., width: ..., ...}`. When the ctx
  changes, every renderer is rebuilt via `mod.new(entry, new_ctx)`.

  Order is append-only with one mutable slot at a time; entries
  never move once added. Render is O(pending) per streaming entry
  and O(1) per finalized entry — finalized entries hit a cache.

  Internal layout:

      %Transcript{
        order:     [id, ...],          # newest-head; append by [id | order]
        data:      %{id => entry},     # current value per slot
        modules:   %{id => mod},       # renderer module per slot
        renderers: %{id => state},     # only present while pending render
        finalized: MapSet of finalized ids
        rendered:  %{id => iodata()}   # cached output per slot
        ctx:       term() | nil        # current render context
      }
  """

  defmodule Renderer do
    @moduledoc """
    Behaviour for entry-level renderers. The Transcript dispatches
    every chunk through these callbacks; it knows nothing about
    entry kinds.

    `new/2` receives the entry and the Transcript's current `ctx`
    (typically `%{theme: ..., width: ..., ...}`). The state is
    expected to be self-contained — `to_iolist/1` takes no extra
    args. When `ctx` changes, Transcript discards the renderer and
    calls `new/2` again with the new context.
    """

    @callback new(entry :: term(), ctx :: term()) :: state :: term()
    @callback put(state :: term(), entry :: term()) :: state :: term()
    @callback finalize(state :: term(), entry :: term()) :: state :: term()
    @callback to_iolist(state :: term()) :: iodata()
  end

  @type id :: term()
  @type entry :: term()
  @type ctx :: term()
  @type t :: %__MODULE__{
          order: [id()],
          data: %{id() => entry()},
          modules: %{id() => module()},
          renderers: %{id() => term()},
          finalized: MapSet.t(),
          rendered: %{id() => iodata()},
          ctx: ctx()
        }

  defstruct order: [],
            data: %{},
            modules: %{},
            renderers: %{},
            finalized: MapSet.new(),
            rendered: %{},
            ctx: nil

  @spec new(ctx()) :: t()
  def new(ctx \\ nil), do: %__MODULE__{ctx: ctx}

  @doc "Append a new entry. `mod` must implement `Renderer`."
  @spec append(t(), id(), entry(), module()) :: t()
  def append(%__MODULE__{} = t, id, entry, mod) when is_atom(mod) do
    %{
      t
      | order: [id | t.order],
        data: Map.put(t.data, id, entry),
        modules: Map.put(t.modules, id, mod),
        renderers: Map.put(t.renderers, id, mod.new(entry, t.ctx))
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
  Finalize an entry. The next `render/2` will materialize its iodata
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
  Render the transcript. If `ctx` is given and differs from the
  stored ctx, every renderer is rebuilt first via `Renderer.new/2`
  (with finalized entries replayed through `finalize/2`).

  Returns the emitted iodata (oldest-first) and the updated
  transcript: pending renderers are folded into `rendered`, and
  finalized renderers are dropped.

  Subsequent calls with the same ctx and unchanged data emit
  purely from `rendered`.
  """
  @spec render(t(), ctx() | nil) :: {iodata(), t()}
  def render(%__MODULE__{} = t, ctx \\ nil) do
    t =
      cond do
        ctx == nil -> t
        ctx === t.ctx -> t
        ctx == t.ctx -> t
        true -> resize(t, ctx)
      end

    {rendered, renderers} =
      Enum.reduce(t.order, {t.rendered, t.renderers}, fn id, {rmap, rrmap} ->
        case Map.fetch(rrmap, id) do
          {:ok, state} ->
            mod = Map.fetch!(t.modules, id)
            io = mod.to_iolist(state)
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
  Resize / re-context: rebuild every renderer via `Renderer.new(entry, ctx)`,
  replaying `finalize/2` for finalized entries. Clears the rendered
  cache; the next `render/2` re-materializes everything.
  """
  @spec resize(t(), ctx()) :: t()
  def resize(%__MODULE__{} = t, ctx) do
    renderers =
      Enum.reduce(t.data, %{}, fn {id, entry}, acc ->
        mod = Map.fetch!(t.modules, id)
        state = mod.new(entry, ctx)
        state = if MapSet.member?(t.finalized, id), do: mod.finalize(state, entry), else: state
        Map.put(acc, id, state)
      end)

    %{t | renderers: renderers, rendered: %{}, ctx: ctx}
  end
end
