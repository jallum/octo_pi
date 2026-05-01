defmodule OctoPi.TUI.Components.Markdown.Render do
  @moduledoc """
  Render-state holder for streaming Markdown.

  Pure data + pure functions over a struct. Holds the source text seen
  so far, a byte-offset checkpoint, and the *rendered* iodata for the
  committed prefix (everything up to the checkpoint). The iodata grows
  monotonically by O(1) prepend-style appends — a tree of `[older, sep,
  newer]` cells whose flatten produces oldest-first byte order.

  The framing is "what's still pending render?" rather than "what's been
  cached." On `to_iolist/1`, committed bytes are emitted from cache; only
  the volatile tail (text past the checkpoint) is freshly lexed and
  rendered. During streaming the volatile tail is bounded by the current
  paragraph length, so per-call cost is O(current paragraph), not
  O(message).

  Width and theme are part of the cache identity. `resize/2` and
  `retheme/2` rerun rendering over the full source once and produce a
  fresh state.

  Out of scope for the module itself: AssistantMessage / Transcript
  wiring (`opi-4dx.10`).
  """

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Components.Markdown.Lexer
  alias OctoPi.TUI.Theme

  @type t :: %__MODULE__{
          source: binary(),
          checkpoint: non_neg_integer(),
          committed: iodata(),
          trailing_kind: atom() | nil,
          width: pos_integer() | nil,
          theme: Theme.t() | nil,
          opts: keyword()
        }

  defstruct source: "",
            checkpoint: 0,
            committed: [],
            trailing_kind: nil,
            width: nil,
            theme: nil,
            opts: []

  @spec new(Theme.t(), pos_integer(), keyword()) :: t()
  def new(theme, width, opts \\ []) when is_integer(width) and width > 0 do
    %__MODULE__{theme: theme, width: width, opts: opts}
  end

  @doc """
  Set the source text. If `new_source` extends the prior source the
  checkpoint and committed iodata are kept; otherwise state is reset and
  rebuilt from `new_source` in one pass.
  """
  @spec put(t(), binary()) :: t()
  def put(%__MODULE__{source: source} = t, source), do: t

  def put(%__MODULE__{source: old} = t, new_source) when is_binary(new_source) do
    if String.starts_with?(new_source, old) do
      advance(%{t | source: new_source})
    else
      reset(%{t | source: new_source, checkpoint: 0, committed: [], trailing_kind: nil})
    end
  end

  @doc """
  Returns the current rendered output as iodata. Committed bytes are
  emitted from cache; only the volatile tail is freshly lexed.
  """
  @spec to_iolist(t()) :: iodata()
  def to_iolist(%__MODULE__{} = t) do
    join_committed_volatile(t.committed, t.trailing_kind, volatile_iodata(t))
  end

  @doc """
  Compatibility helper: returns a list of `String.t()` lines, matching
  the legacy `Markdown.render/2` shape.
  """
  @spec to_lines(t()) :: [String.t()]
  def to_lines(%__MODULE__{} = t) do
    case IO.iodata_to_binary(to_iolist(t)) do
      "" -> []
      bin -> String.split(bin, "\n")
    end
  end

  @doc """
  Fold the volatile tail into committed and return final iodata. The
  state is consumed; callers typically drop the renderer afterward.
  """
  @spec finalize(t()) :: {iodata(), t()}
  def finalize(%__MODULE__{} = t) do
    tail_size = byte_size(t.source) - t.checkpoint

    new_state =
      if tail_size == 0 do
        t
      else
        tail = binary_part(t.source, t.checkpoint, tail_size)
        {seg, kind} = render_segment(tail, t)
        {committed, new_kind} = append_segment(t.committed, t.trailing_kind, seg, kind)

        %{
          t
          | checkpoint: byte_size(t.source),
            committed: committed,
            trailing_kind: new_kind
        }
      end

    {to_iolist(new_state), new_state}
  end

  @doc """
  Change the render width. Triggers a single full rerun over the source.
  """
  @spec resize(t(), pos_integer()) :: t()
  def resize(%__MODULE__{width: w} = t, w), do: t

  def resize(%__MODULE__{} = t, new_width) when is_integer(new_width) and new_width > 0 do
    reset(%{t | width: new_width, checkpoint: 0, committed: [], trailing_kind: nil})
  end

  @doc """
  Change the theme. Triggers a single full rerun over the source.
  """
  @spec retheme(t(), Theme.t()) :: t()
  def retheme(%__MODULE__{theme: theme} = t, theme), do: t

  def retheme(%__MODULE__{} = t, new_theme) do
    reset(%{t | theme: new_theme, checkpoint: 0, committed: [], trailing_kind: nil})
  end

  # ── internals ──────────────────────────────────────────────────

  defp reset(%__MODULE__{} = t), do: advance(t)

  defp advance(%__MODULE__{source: source, checkpoint: cp} = t) do
    new_cp = find_checkpoint(source, cp)

    if new_cp > cp do
      seg_text = binary_part(source, cp, new_cp - cp)
      {seg, kind} = render_segment(seg_text, t)
      {committed, new_kind} = append_segment(t.committed, t.trailing_kind, seg, kind)
      %{t | checkpoint: new_cp, committed: committed, trailing_kind: new_kind}
    else
      t
    end
  end

  # Append a rendered segment to `committed` using a separator that
  # depends on the prior segment's last block. `:list` blocks don't
  # emit a trailing blank in the legacy renderer (`render_block` for
  # `:list` ignores `next`), so we mirror that here. Empty segments
  # are no-ops and don't update the trailing kind.
  defp append_segment(committed, prior_kind, [], _kind), do: {committed, prior_kind}
  defp append_segment([], _prior_kind, seg, kind), do: {seg, kind}

  defp append_segment(committed, prior_kind, seg, kind) do
    {[committed, separator_for(prior_kind), seg], kind}
  end

  defp join_committed_volatile([], _kind, volatile), do: volatile
  defp join_committed_volatile(committed, _kind, []), do: committed

  defp join_committed_volatile(committed, kind, volatile) do
    [committed, separator_for(kind), volatile]
  end

  defp separator_for(:list), do: "\n"
  defp separator_for(_), do: "\n\n"

  defp volatile_iodata(%__MODULE__{source: source, checkpoint: cp} = t) do
    tail_size = byte_size(source) - cp

    if tail_size == 0 do
      []
    else
      tail = binary_part(source, cp, tail_size)
      {seg, _kind} = render_segment(tail, t)
      seg
    end
  end

  # Render a slab to `{iodata, last_block_kind}`. `last_block_kind` is
  # the atom kind of the slab's final block (`:paragraph`, `:list`,
  # `:heading`, …) or `nil` if no blocks were produced.
  defp render_segment("", _t), do: {[], nil}

  defp render_segment(text, %__MODULE__{theme: theme, width: width, opts: opts}) do
    normalized = String.replace(text, "\t", "   ")
    blocks = Lexer.tokenize(normalized)

    case Markdown.render_blocks_to_lines(blocks, theme, opts, width) do
      [] -> {[], nil}
      lines -> {Enum.intersperse(lines, "\n"), last_block_kind(blocks)}
    end
  end

  defp last_block_kind([]), do: nil

  defp last_block_kind(blocks) do
    case List.last(blocks) do
      tuple when is_tuple(tuple) -> elem(tuple, 0)
      atom when is_atom(atom) -> atom
      _ -> nil
    end
  end

  # Walk `source` from `from` to end and find the latest paragraph
  # boundary — a blank line outside an open code fence — with a `from`
  # fallback if none exists.
  defp find_checkpoint(source, from) do
    suffix = binary_part(source, from, byte_size(source) - from)
    lines = String.split(suffix, "\n")
    scan_lines(lines, from, from, false, nil)
  end

  defp scan_lines([], _offset, _from, _in_fence, last), do: last || 0

  defp scan_lines([_last_line], _offset, from, _in_fence, last), do: last || from

  defp scan_lines([line | rest], offset, from, in_fence, last) do
    next_offset = offset + byte_size(line) + 1

    cond do
      fence_marker?(line) ->
        scan_lines(rest, next_offset, from, not in_fence, last)

      in_fence ->
        scan_lines(rest, next_offset, from, in_fence, last)

      String.trim(line) == "" ->
        scan_lines(rest, next_offset, from, in_fence, next_offset)

      true ->
        scan_lines(rest, next_offset, from, in_fence, last)
    end
  end

  defp fence_marker?(line), do: String.match?(line, ~r/^\s{0,3}(```|~~~)/)
end
