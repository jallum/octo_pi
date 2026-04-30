defmodule OctoPi.TUI.Components.AssistantMessage do
  @moduledoc """
  Renders an assistant turn as a stack of content blocks. Mirrors the
  `Transcript` shape from `opi-4dx.8` at the message-internal level:
  blocks are keyed by stable `block_id` (the index assigned by the
  decoder + agent), each with its own renderer state that persists
  across delta arrivals. Rendering a finalized block at a known width
  reuses cached iodata — no re-lex, no `markdown.render` telemetry.

  Per-kind dispatch:

    * `:text` → `Markdown.Render` (incremental lexer + cached committed
      iodata; consumes successive snapshots via `put/2`).
    * `:thinking` → simple ANSI-italic wrap; no per-block cache, the
      cost is dominated by `WrapAnsi.wrap`.
    * `:tool_call` → not rendered here (tool execution is its own
      transcript entry).

  Caching identity is `(theme, width)`. Caller threads both through
  `update_content/2` (or directly via `put_block/4`); on changes the
  module rebuilds renderer state.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.Markdown.Render, as: MdRender
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.WrapAnsi

  @osc133_zone_start "\e]133;A\a"
  @osc133_zone_end "\e]133;B\a"
  @osc133_zone_final "\e]133;C\a"

  @type kind :: :text | :thinking | :tool_call
  @type content_block :: {kind(), String.t()}

  @type block_state :: %{
          required(:kind) => kind(),
          required(:snapshot) => binary(),
          required(:finalized?) => boolean(),
          optional(:render_state) => MdRender.t() | nil
        }

  @type t :: %__MODULE__{
          theme: Theme.t() | nil,
          msg_id: String.t() | nil,
          content: [content_block()],
          blocks: %{non_neg_integer() => block_state()},
          width: pos_integer() | nil,
          stop_reason: nil | :aborted | :error,
          error_message: String.t() | nil,
          hide_thinking: boolean(),
          hidden_thinking_label: String.t(),
          has_tool_calls: boolean(),
          finalized?: boolean(),
          streaming?: boolean()
        }

  defstruct theme: nil,
            msg_id: nil,
            content: [],
            blocks: %{},
            width: nil,
            stop_reason: nil,
            error_message: nil,
            hide_thinking: false,
            hidden_thinking_label: "Thinking...",
            has_tool_calls: false,
            finalized?: false,
            streaming?: false

  @spec new(Theme.t() | nil, keyword()) :: t()
  def new(theme, opts \\ []) do
    msg = struct!(__MODULE__, Keyword.put(opts, :theme, theme))
    %{msg | blocks: build_blocks(%{}, msg.content, msg.theme, msg.width)}
  end

  @doc """
  Apply meta + content updates. Recognised keys:

    * `:content` — replace the content list (per-block state is
      preserved when the kind at a given index is unchanged).
    * `:theme`, `:width` — change the cache identity. Existing text
      renderers are rethemed/resized rather than rebuilt from scratch.
    * everything else (`:stop_reason`, `:finalized?`, `:streaming?`,
      `:has_tool_calls`, `:error_message`, `:msg_id`) — set verbatim.
  """
  @spec update_content(t(), keyword()) :: t()
  def update_content(%__MODULE__{} = msg, updates) do
    meta = Keyword.drop(updates, [:content, :theme, :width])
    msg = struct!(msg, meta)

    msg =
      case Keyword.fetch(updates, :theme) do
        {:ok, t} when t != msg.theme -> %{msg | theme: t, blocks: retheme_blocks(msg.blocks, t)}
        _ -> msg
      end

    msg =
      case Keyword.fetch(updates, :width) do
        {:ok, w} when w != msg.width -> %{msg | width: w, blocks: resize_blocks(msg.blocks, w)}
        _ -> msg
      end

    case Keyword.fetch(updates, :content) do
      {:ok, content} ->
        blocks = build_blocks(msg.blocks, content, msg.theme, msg.width)
        %{msg | content: content, blocks: blocks}

      :error ->
        msg
    end
  end

  @doc """
  Apply a single block update by stable id. Cheaper than rebuilding
  the whole content list — touches only the one slot.
  """
  @spec put_block(t(), non_neg_integer(), kind(), binary()) :: t()
  def put_block(%__MODULE__{} = msg, block_id, kind, snapshot) when is_integer(block_id) do
    prior = Map.get(msg.blocks, block_id)
    new_block = build_block(prior, kind, snapshot, msg.theme, msg.width)
    blocks = Map.put(msg.blocks, block_id, new_block)
    %{msg | blocks: blocks, content: blocks_to_content(blocks)}
  end

  @doc "Mark a block finalized; the next render folds its volatile tail into cache."
  @spec finalize_block(t(), non_neg_integer()) :: t()
  def finalize_block(%__MODULE__{} = msg, block_id) do
    case Map.get(msg.blocks, block_id) do
      nil ->
        msg

      %{render_state: %MdRender{} = r} = b ->
        {_io, r2} = MdRender.finalize(r)
        %{msg | blocks: Map.put(msg.blocks, block_id, %{b | finalized?: true, render_state: r2})}

      b ->
        %{msg | blocks: Map.put(msg.blocks, block_id, %{b | finalized?: true})}
    end
  end

  # ── block-state construction ────────────────────────────────────

  defp build_blocks(prior, content, theme, width) do
    content
    |> Enum.with_index()
    |> Enum.into(%{}, fn {{kind, snapshot}, idx} ->
      {idx, build_block(Map.get(prior, idx), kind, snapshot, theme, width)}
    end)
  end

  defp build_block(nil, kind, snapshot, theme, width),
    do: fresh_block(kind, snapshot, theme, width)

  # Same kind + same snapshot: backfill a missing renderer if theme +
  # width are now known, otherwise no-op.
  defp build_block(%{kind: :text, snapshot: snapshot, render_state: nil} = b, :text, snapshot, theme, width)
       when not is_nil(theme) and is_integer(width) do
    r = MdRender.new(theme, width, padding_x: 1)
    %{b | render_state: MdRender.put(r, normalize_md(snapshot))}
  end

  defp build_block(%{kind: kind, snapshot: snapshot} = b, kind, snapshot, _theme, _width), do: b

  defp build_block(%{kind: :text, render_state: %MdRender{} = r} = b, :text, snapshot, _theme, _width) do
    %{b | snapshot: snapshot, render_state: MdRender.put(r, normalize_md(snapshot))}
  end

  defp build_block(%{kind: :text, render_state: nil} = b, :text, snapshot, theme, width)
       when not is_nil(theme) and is_integer(width) do
    r = MdRender.new(theme, width, padding_x: 1)
    %{b | snapshot: snapshot, render_state: MdRender.put(r, normalize_md(snapshot))}
  end

  defp build_block(%{kind: kind} = b, kind, snapshot, _theme, _width) do
    %{b | snapshot: snapshot}
  end

  defp build_block(_, kind, snapshot, theme, width),
    do: fresh_block(kind, snapshot, theme, width)

  defp fresh_block(:text, snapshot, theme, width) when not is_nil(theme) and is_integer(width) do
    r = MdRender.new(theme, width, padding_x: 1)
    %{kind: :text, snapshot: snapshot, finalized?: false, render_state: MdRender.put(r, normalize_md(snapshot))}
  end

  defp fresh_block(:text, snapshot, _theme, _width) do
    %{kind: :text, snapshot: snapshot, finalized?: false, render_state: nil}
  end

  defp fresh_block(kind, snapshot, _theme, _width) do
    %{kind: kind, snapshot: snapshot, finalized?: false}
  end

  defp blocks_to_content(blocks) do
    blocks
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_idx, %{kind: k, snapshot: s}} -> {k, s} end)
  end

  defp retheme_blocks(blocks, theme) do
    Map.new(blocks, fn
      {idx, %{kind: :text, render_state: %MdRender{} = r} = b} ->
        {idx, %{b | render_state: MdRender.retheme(r, theme)}}

      pair ->
        pair
    end)
  end

  defp resize_blocks(blocks, width) do
    Map.new(blocks, fn
      {idx, %{kind: :text, render_state: %MdRender{} = r} = b} ->
        {idx, %{b | render_state: MdRender.resize(r, width)}}

      pair ->
        pair
    end)
  end

  defp normalize_md(text), do: text |> String.trim() |> String.replace("\t", "   ")

  # ── render ──────────────────────────────────────────────────────

  @impl true
  def render(%__MODULE__{} = msg, width) do
    lines = render_content(msg, width)

    if not msg.has_tool_calls and lines != [],
      do: wrap_osc133(lines),
      else: lines
  end

  defp render_content(%__MODULE__{} = msg, width) do
    # Walk content with index — block_id is the position. If a
    # per-block state exists in `msg.blocks` use it (cached path);
    # otherwise materialize ad-hoc (struct-literal construction or
    # uncached tests).
    indexed =
      msg.content
      |> Enum.with_index()
      |> Enum.filter(fn {{k, s}, _idx} ->
        k in [:text, :thinking] and String.trim(s) != ""
      end)

    has_visible = indexed != []

    content_lines =
      if has_visible do
        block_count = length(indexed)

        [""] ++
          Enum.flat_map(Enum.with_index(indexed), fn {{{kind, snapshot}, idx}, i} ->
            block = Map.get(msg.blocks, idx) || %{kind: kind, snapshot: snapshot, finalized?: false}
            render_block(block, msg, width, i < block_count - 1)
          end)
      else
        []
      end

    content_lines ++ render_status(msg, has_visible)
  end

  defp render_block(%{kind: :text, snapshot: snapshot} = block, msg, width, _has_after) do
    render_markdown_with_telemetry(block, msg, width, snapshot)
  end

  defp render_block(%{kind: :thinking, snapshot: snapshot}, msg, width, has_after) do
    lines = render_thinking(snapshot, msg, width)
    if has_after, do: lines ++ [""], else: lines
  end

  defp render_block(_, _msg, _width, _has_after), do: []

  defp render_markdown_with_telemetry(%{render_state: %MdRender{width: w}} = block, msg, width, snapshot)
       when w == width do
    # Cache hit: width matches stamped state. Emit `to_lines` directly,
    # no telemetry span — the renderer's committed iodata covers the
    # bulk; only the volatile tail (if any) re-lexes inside `to_lines`.
    case block.render_state do
      %MdRender{} = r ->
        case MdRender.to_lines(r) do
          [] -> []
          lines -> lines
        end

      _ ->
        render_markdown_uncached(msg, width, snapshot)
    end
  end

  defp render_markdown_with_telemetry(_block, msg, width, snapshot),
    do: render_markdown_uncached(msg, width, snapshot)

  defp render_markdown_uncached(msg, width, snapshot) do
    start_meta = %{
      msg_id: msg.msg_id,
      streaming?: msg.streaming?,
      width: width
    }

    :telemetry.span(
      [:octo_pi_tui, :markdown, :render],
      start_meta,
      fn ->
        r =
          MdRender.new(msg.theme, width, padding_x: 1)
          |> MdRender.put(normalize_md(snapshot))

        lines = MdRender.to_lines(r)

        stop_meta =
          Map.merge(start_meta, %{
            text_bytes: byte_size(snapshot),
            line_count: length(lines)
          })

        {lines, stop_meta}
      end
    )
  end

  defp render_thinking(_text, %{hide_thinking: true} = msg, _width) do
    label = msg.hidden_thinking_label
    [" " <> Theme.fg(msg.theme, :thinking_text, Theme.italic(label))]
  end

  defp render_thinking(text, %{theme: theme}, width) do
    content_width = max(1, width - 1)

    text
    |> WrapAnsi.wrap(content_width)
    |> Enum.map(fn line ->
      " " <> Theme.fg(theme, :thinking_text, Theme.italic(line))
    end)
  end

  defp render_status(%{stop_reason: nil}, _has_visible), do: []
  defp render_status(%{has_tool_calls: true}, _has_visible), do: []

  defp render_status(%{stop_reason: :aborted} = msg, _has_visible) do
    text =
      if msg.error_message && msg.error_message != "Request was aborted",
        do: msg.error_message,
        else: "Operation aborted"

    ["", Theme.fg(msg.theme, :error, text)]
  end

  defp render_status(%{stop_reason: :error} = msg, _has_visible) do
    text = "Error: #{msg.error_message || "Unknown error"}"
    ["", Theme.fg(msg.theme, :error, text)]
  end

  defp render_status(_msg, _has_visible), do: []

  defp wrap_osc133([single]) do
    [@osc133_zone_start <> single <> @osc133_zone_end <> @osc133_zone_final]
  end

  defp wrap_osc133([first | rest]) do
    {middle, [last]} = Enum.split(rest, -1)
    tagged_last = @osc133_zone_end <> @osc133_zone_final <> last
    [@osc133_zone_start <> first | middle] ++ [tagged_last]
  end
end
