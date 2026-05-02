defmodule OctoPi.TUI.Components.AssistantMessage.TextBlock do
  @moduledoc """
  Streaming transcript entry for `:text` content blocks. Wraps
  `Markdown.Render` (`opi-4dx.7`): incremental lex with cached
  committed iodata, volatile tail re-lexed each call.

  `:snapshot` is the canonical text. `:md_render` is the cached
  incremental markdown renderer. The latter bakes theme/width at
  build time; if the live ctx differs from what the cached renderer
  was built against, `render/2` rebuilds from scratch.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown.Render, as: MdRender
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM

  defstruct snapshot: "", md_render: nil

  @type t :: %__MODULE__{
          snapshot: binary(),
          md_render: MdRender.t() | nil
        }

  @impl true
  def update(%__MODULE__{md_render: %MdRender{} = md} = self, snapshot),
    do: %{self | snapshot: snapshot, md_render: MdRender.put(md, snapshot)}

  def update(%__MODULE__{} = self, snapshot), do: %{self | snapshot: snapshot}

  @impl true
  def finalize(%__MODULE__{md_render: nil} = self, snapshot), do: %{self | snapshot: snapshot}

  def finalize(%__MODULE__{md_render: %MdRender{} = md} = self, snapshot) do
    {_lines, md_sealed} = md |> MdRender.put(snapshot) |> MdRender.finalize()
    %{self | snapshot: snapshot, md_render: md_sealed}
  end

  @impl true
  # Hot path: cached MdRender's baked theme/width matches live ctx.
  def render(
        %__MODULE__{md_render: %MdRender{theme: t, width: w} = md} = self,
        %RenderContext{theme: t, width: w} = ctx
      )
      when not is_nil(t) and is_integer(w) do
    instrument(ctx, fn -> {self, MdRender.to_lines(md), nil} end)
  end

  # Cold path: no cache or ctx differs — (re)build from snapshot.
  def render(%__MODULE__{snapshot: s} = self, %RenderContext{} = ctx) do
    instrument(ctx, fn ->
      md =
        ctx.theme
        |> MdRender.new(ctx.width, padding_x: ctx.padding_x)
        |> MdRender.put(s)

      {%{self | md_render: md}, MdRender.to_lines(md), nil}
    end)
  end

  defp instrument(ctx, fun) do
    start_meta = %{width: ctx.width}

    :telemetry.span([:octo_pi_tui, :markdown, :render], start_meta, fn ->
      {self, lines, frame_ms} = fun.()
      vnode = %VDOM.VLines{lines: lines}

      stop_meta =
        Map.merge(start_meta, %{
          line_count: length(lines),
          text_bytes: byte_size(self.snapshot)
        })

      {{self, vnode, frame_ms}, stop_meta}
    end)
  end
end
