defmodule OctoPi.TUI.Components.AssistantMessage do
  @moduledoc """
  Renders an assistant turn as a stack of content blocks. Backed by
  the shared `OctoPi.TUI.Transcript` shape from `opi-4dx.8`: blocks
  are keyed by stable `block_id`, each with its own renderer state
  that persists across delta arrivals. Rendering a finalized block
  at the stamped ctx reuses cached iodata.

  Per-kind dispatch via small `Transcript.Renderer` adapters in
  `AssistantMessage.{TextBlock,ThinkingBlock}`:

    * `:text` → wraps `Markdown.Render` (incremental lex + cached
      committed iodata).
    * `:thinking` → simple ANSI-italic wrap.
    * `:tool_call` → not rendered here.

  Cache identity is `%{theme:, width:}`. Caller threads both
  through `update_content/2` (or directly via `put_block/4`); on
  changes Transcript rebuilds renderer state.
  """

  @behaviour OctoPi.TUI.Component

  alias OctoPi.TUI.Components.AssistantMessage.{TextBlock, ThinkingBlock}
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.Transcript

  @osc133_zone_start "\e]133;A\a"
  @osc133_zone_end "\e]133;B\a"
  @osc133_zone_final "\e]133;C\a"

  @type kind :: :text | :thinking | :tool_call
  @type content_block :: {kind(), String.t()}

  @type t :: %__MODULE__{
          theme: Theme.t() | nil,
          msg_id: String.t() | nil,
          content: [content_block()],
          blocks: Transcript.t(),
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
            blocks: %Transcript{},
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
    blocks = Transcript.new(ctx_for(msg, msg.width))
    blocks = build_initial(blocks, msg.content)
    %{msg | blocks: blocks}
  end

  @doc """
  Apply meta + content updates. Recognised keys:

    * `:content` — replace the content list. Per-block state is
      preserved when the kind at a given index is unchanged.
    * `:theme`, `:width` — change the cache identity. Existing
      renderers are rebuilt via `Transcript.resize/2` with the new ctx.
    * everything else (`:stop_reason`, `:finalized?`, `:streaming?`,
      `:has_tool_calls`, `:error_message`, `:msg_id`) — set verbatim.
  """
  @spec update_content(t(), keyword()) :: t()
  def update_content(%__MODULE__{} = msg, updates) do
    meta = Keyword.drop(updates, [:content, :theme, :width])
    msg = struct!(msg, meta)

    msg =
      case {Keyword.fetch(updates, :theme), Keyword.fetch(updates, :width)} do
        {:error, :error} ->
          msg

        {theme_kv, width_kv} ->
          theme = with({:ok, t} <- theme_kv, do: t, else: (_ -> msg.theme))
          width = with({:ok, w} <- width_kv, do: w, else: (_ -> msg.width))

          if theme == msg.theme and width == msg.width do
            msg
          else
            new_msg = %{msg | theme: theme, width: width}
            %{new_msg | blocks: Transcript.resize(new_msg.blocks, ctx_for(new_msg, width))}
          end
      end

    case Keyword.fetch(updates, :content) do
      {:ok, content} -> apply_content(msg, content)
      :error -> msg
    end
  end

  @doc """
  Apply a single block update by stable id. Cheaper than rebuilding
  the whole content list — touches only the one slot.
  """
  @spec put_block(t(), non_neg_integer(), kind(), binary()) :: t()
  def put_block(%__MODULE__{} = msg, block_id, kind, snapshot) when is_integer(block_id) do
    blocks =
      if Transcript.has_entry?(msg.blocks, block_id) do
        Transcript.update(msg.blocks, block_id, snapshot)
      else
        Transcript.append(msg.blocks, block_id, snapshot, renderer_for(kind))
      end

    %{msg | blocks: blocks, content: blocks_to_content(blocks)}
  end

  @doc "Mark a block finalized; the next render folds its volatile tail into cache."
  @spec finalize_block(t(), non_neg_integer()) :: t()
  def finalize_block(%__MODULE__{} = msg, block_id) do
    case Transcript.get_data(msg.blocks, block_id) do
      nil -> msg
      entry -> %{msg | blocks: Transcript.finalize(msg.blocks, block_id, entry)}
    end
  end

  # ── internal: building blocks from a content list ───────────────

  defp build_initial(blocks, content) do
    content
    |> Enum.with_index()
    |> Enum.reduce(blocks, fn {{kind, snapshot}, idx}, acc ->
      Transcript.append(acc, idx, snapshot, renderer_for(kind))
    end)
  end

  # `apply_content` reconciles a freshly-passed content list with
  # the current Transcript. For each index: if the kind is unchanged,
  # update; otherwise re-append. Indices not in the new list are
  # dropped (rare — content only grows mid-stream).
  defp apply_content(msg, content) do
    new_blocks =
      content
      |> Enum.with_index()
      |> Enum.reduce(reset_blocks(msg), fn {{kind, snapshot}, idx}, acc ->
        case current_kind(msg.blocks, idx) do
          ^kind ->
            cond do
              Transcript.has_entry?(acc, idx) -> Transcript.update(acc, idx, snapshot)
              true -> Transcript.append(acc, idx, snapshot, renderer_for(kind))
            end

          _ ->
            Transcript.append(acc, idx, snapshot, renderer_for(kind))
        end
      end)

    %{msg | content: content, blocks: new_blocks}
  end

  defp reset_blocks(msg), do: Transcript.new(msg.blocks.ctx)

  defp current_kind(%Transcript{} = t, idx) do
    if Transcript.has_entry?(t, idx) do
      case Transcript.fetch_module!(t, idx) do
        TextBlock -> :text
        ThinkingBlock -> :thinking
        _ -> nil
      end
    end
  end

  defp renderer_for(:text), do: TextBlock
  defp renderer_for(:thinking), do: ThinkingBlock
  defp renderer_for(_), do: ThinkingBlock

  defp blocks_to_content(%Transcript{entries: entries}) do
    entries
    |> Enum.sort_by(fn {idx, _} -> idx end)
    |> Enum.map(fn {_, e} -> {kind_for(e.module), e.data} end)
  end

  defp kind_for(TextBlock), do: :text
  defp kind_for(ThinkingBlock), do: :thinking
  defp kind_for(_), do: :text

  defp ctx_from(theme, width, opts) do
    base = %{theme: theme, width: width, padding_x: 1}
    Enum.into(opts, base)
  end

  defp ctx_for(%__MODULE__{} = msg, width) do
    ctx_from(msg.theme, width,
      hide_thinking: msg.hide_thinking,
      hidden_thinking_label: msg.hidden_thinking_label
    )
  end

  # ── render ──────────────────────────────────────────────────────

  @impl true
  def render(%__MODULE__{} = msg, width) do
    lines = render_content(msg, width)

    if not msg.has_tool_calls and lines != [],
      do: wrap_osc133(lines),
      else: lines
  end

  defp render_content(%__MODULE__{} = msg, width) do
    visible =
      msg.content
      |> Enum.with_index()
      |> Enum.filter(fn {{k, s}, _idx} -> k in [:text, :thinking] and String.trim(s) != "" end)

    has_visible = visible != []

    content_lines =
      if has_visible do
        text_bytes = Enum.reduce(visible, 0, fn {{_k, s}, _idx}, acc -> acc + byte_size(s) end)

        start_meta = %{msg_id: msg.msg_id, streaming?: msg.streaming?, width: width}

        :telemetry.span(
          [:octo_pi_tui, :markdown, :render],
          start_meta,
          fn ->
            # When the call width matches the stamped ctx width, reuse
            # the stored ctx by reference — Transcript.render then
            # short-circuits its ctx-equality check.
            ctx =
              cond do
                msg.blocks.ctx != nil and Map.get(msg.blocks.ctx, :width) == width -> msg.blocks.ctx
                true -> ctx_for(msg, width)
              end

            # Tolerate struct-literal construction (`%AssistantMessage{content: [...]}`)
            # that bypasses `new/2`: build the Transcript on the fly.
            blocks =
              if msg.blocks.order == [] and msg.content != [],
                do: build_initial(Transcript.new(ctx), msg.content),
                else: msg.blocks

            {iodata, _t} = Transcript.render(blocks, ctx)

            bin = IO.iodata_to_binary(iodata)
            block_lines = if bin == "", do: [], else: String.split(bin, "\n")
            lines = [""] ++ interleave_blocks(visible, block_lines)

            stop_meta =
              Map.merge(start_meta, %{
                text_bytes: text_bytes,
                line_count: length(lines)
              })

            {lines, stop_meta}
          end
        )
      else
        []
      end

    content_lines ++ render_status(msg, has_visible)
  end

  # Each block emits its own iodata into the Transcript's iolist.
  # Thinking-block separators (a blank line if a non-thinking block
  # follows) are handled by emitting blank lines at appropriate
  # transitions. For now, the simple split-by-newline reproduces the
  # legacy stack-of-lines visual.
  defp interleave_blocks(_visible, lines), do: lines

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
