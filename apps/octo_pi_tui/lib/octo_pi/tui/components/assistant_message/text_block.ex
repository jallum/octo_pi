defmodule OctoPi.TUI.Components.AssistantMessage.TextBlock do
  @moduledoc """
  Transcript renderer adapter for `:text` content blocks. Wraps
  `Markdown.Render` (`opi-4dx.7`): incremental lex with cached
  committed iodata, volatile tail re-lexed each call.

  `entry` is the snapshot binary. `ctx` is
  `%{theme: Theme.t() | nil, width: pos_integer() | nil, padding_x: ...}`.
  When theme/width are nil, state is held in a deferred form that
  defers building the renderer until ctx is complete; `to_iolist/1`
  on a deferred state returns empty (a render at known dims comes
  through a `Transcript.resize/2` and rebuilds via `new/2`).
  """

  @behaviour OctoPi.TUI.Transcript.Renderer

  alias OctoPi.TUI.Components.Markdown.Render, as: MdRender

  @type state :: MdRender.t() | {:deferred, binary()}

  # Trim/tab normalization is intentionally NOT done here — see
  # `Markdown.Render`, which applies tab→spaces to the volatile tail
  # only (bounded by current-paragraph size). Allocating a fresh
  # full-snapshot binary per chunk would defeat the incremental cache.

  @impl true
  def new(snapshot, %{theme: theme, width: width} = ctx)
      when not is_nil(theme) and is_integer(width) do
    opts = ctx |> Map.drop([:theme, :width]) |> Enum.to_list()
    MdRender.new(theme, width, opts) |> MdRender.put(snapshot)
  end

  def new(snapshot, _ctx), do: {:deferred, snapshot}

  @impl true
  def put({:deferred, _}, snapshot), do: {:deferred, snapshot}
  def put(%MdRender{} = r, snapshot), do: MdRender.put(r, snapshot)

  @impl true
  def finalize({:deferred, _}, snapshot), do: {:deferred, snapshot}

  def finalize(%MdRender{} = r, snapshot) do
    {_, r2} = MdRender.put(r, snapshot) |> MdRender.finalize()
    r2
  end

  # Convention: every renderer terminates its own lines. MdRender's
  # output joins committed/volatile segments without a trailing
  # newline; we add one so the next entry starts on its own line.
  @impl true
  def to_iolist({:deferred, _}), do: []

  def to_iolist(%MdRender{} = r) do
    case MdRender.to_iolist(r) do
      [] -> []
      io -> [io, "\n"]
    end
  end
end
