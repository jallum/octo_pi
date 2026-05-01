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
        entries:   %{id => %Entry{}},  # data + module + live renderer per slot
        streaming: MapSet of in-flight ids (added on append, removed on finalize)
        rendered:  %{id => iodata()}   # cached output per slot
        ctx:       term() | nil        # current render context
      }

  We track `streaming` (small, bounded by concurrent in-flight work)
  rather than `finalized` (would grow monotonically with the
  transcript). An entry is finalized iff it's present in `entries`
  and absent from `streaming`.
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

  defmodule Entry do
    @moduledoc "Per-slot triple: canonical data, renderer module, live renderer state."
    @type t :: %__MODULE__{
            data: term(),
            module: module(),
            renderer: term()
          }
    defstruct [:data, :module, :renderer]
  end

  @type id :: term()
  @type entry :: term()
  @type ctx :: term()
  @type t :: %__MODULE__{
          order: [id()],
          entries: %{id() => Entry.t()},
          streaming: MapSet.t(),
          rendered: %{id() => iodata()},
          ctx: ctx()
        }

  defstruct order: [],
            entries: %{},
            streaming: MapSet.new(),
            rendered: %{},
            ctx: nil

  @spec new(ctx()) :: t()
  def new(ctx \\ nil), do: %__MODULE__{ctx: ctx}

  @doc "Append a new entry. `mod` must implement `Renderer`."
  @spec append(t(), id(), entry(), module()) :: t()
  def append(%__MODULE__{} = t, id, data, mod) when is_atom(mod) do
    e = %Entry{data: data, module: mod, renderer: mod.new(data, t.ctx)}

    %{
      t
      | order: [id | t.order],
        entries: Map.put(t.entries, id, e),
        streaming: MapSet.put(t.streaming, id)
    }
  end

  @doc "Update an existing entry mid-stream. Renderer must still be live."
  @spec update(t(), id(), entry()) :: t()
  def update(%__MODULE__{} = t, id, data) do
    %Entry{module: mod, renderer: r} = e = Map.fetch!(t.entries, id)
    e = %{e | data: data, renderer: mod.put(r, data)}
    %{t | entries: Map.put(t.entries, id, e)}
  end

  @doc """
  Finalize an entry. The next `render/2` will materialize its iodata
  into `rendered` and drop the renderer.
  """
  @spec finalize(t(), id(), entry()) :: t()
  def finalize(%__MODULE__{} = t, id, data) do
    %Entry{module: mod, renderer: r} = e = Map.fetch!(t.entries, id)
    e = %{e | data: data, renderer: mod.finalize(r, data)}
    %{t | entries: Map.put(t.entries, id, e), streaming: MapSet.delete(t.streaming, id)}
  end

  @doc "Whether `id` is present in the transcript."
  @spec has_entry?(t(), id()) :: boolean()
  def has_entry?(%__MODULE__{entries: entries}, id), do: Map.has_key?(entries, id)

  @doc """
  True if any entry has not yet been finalized. O(1) via `MapSet.size/1`
  on the small in-flight set.
  """
  @spec streaming?(t()) :: boolean()
  def streaming?(%__MODULE__{streaming: streaming}), do: MapSet.size(streaming) > 0

  @doc "Whether `id` is present and finalized (i.e., not in the streaming set)."
  @spec finalized?(t(), id()) :: boolean()
  def finalized?(%__MODULE__{entries: entries, streaming: streaming}, id),
    do: Map.has_key?(entries, id) and not MapSet.member?(streaming, id)

  @doc "Fetch the canonical data for `id`. Raises if not present."
  @spec fetch_data!(t(), id()) :: entry()
  def fetch_data!(%__MODULE__{entries: entries}, id), do: Map.fetch!(entries, id).data

  @doc "Get the canonical data for `id`, or `default` if not present."
  @spec get_data(t(), id(), term()) :: entry() | term()
  def get_data(%__MODULE__{entries: entries}, id, default \\ nil) do
    case Map.get(entries, id) do
      nil -> default
      %Entry{data: data} -> data
    end
  end

  @doc "Fetch the renderer module for `id`. Raises if not present."
  @spec fetch_module!(t(), id()) :: module()
  def fetch_module!(%__MODULE__{entries: entries}, id), do: Map.fetch!(entries, id).module

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

    {rendered, entries} =
      Enum.reduce(t.order, {t.rendered, t.entries}, fn id, {rmap, emap} ->
        case Map.fetch(emap, id) do
          {:ok, %Entry{module: mod, renderer: r} = e} when r != nil ->
            io = mod.to_iolist(r)
            rmap2 = Map.put(rmap, id, io)
            emap2 = if MapSet.member?(t.streaming, id), do: emap, else: Map.put(emap, id, %{e | renderer: nil})
            {rmap2, emap2}

          _ ->
            {rmap, emap}
        end
      end)

    iolist =
      t.order
      |> Enum.reverse()
      |> Enum.map(&Map.get(rendered, &1, []))

    {iolist, %{t | rendered: rendered, entries: entries}}
  end

  @doc """
  Resize / re-context: rebuild every renderer via `Renderer.new(entry, ctx)`,
  replaying `finalize/2` for finalized entries. Clears the rendered
  cache; the next `render/2` re-materializes everything.
  """
  @spec resize(t(), ctx()) :: t()
  def resize(%__MODULE__{} = t, ctx) do
    entries =
      Map.new(t.entries, fn {id, %Entry{data: data, module: mod} = e} ->
        r = mod.new(data, ctx)
        r = if MapSet.member?(t.streaming, id), do: r, else: mod.finalize(r, data)
        {id, %{e | renderer: r}}
      end)

    %{t | entries: entries, rendered: %{}, ctx: ctx}
  end
end
