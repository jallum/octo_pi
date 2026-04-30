defmodule OctoPi.TUI.Components.Markdown.Stream do
  @moduledoc """
  Incremental Markdown lexer state for streaming text.

  Pure data + pure functions over a struct. Holds the source text seen
  so far, a byte-offset checkpoint, and the AST blocks committed up to
  that checkpoint. On `put/2` with an extending text, advances the
  checkpoint to the latest *paragraph boundary* (a blank line outside an
  open code fence) and lexes only the segment between the old and new
  checkpoint, appending to the committed block list.

  The unlexed tail (everything past the checkpoint) is re-lexed from
  scratch on every `blocks/1` call. The point of the wrapper is that
  during streaming, `tail` is bounded by the current paragraph length,
  not by total message length — so render cost is O(current paragraph)
  rather than O(message).

  Correctness: `Lexer.tokenize/1` is line-oriented and has no global
  state spanning blank lines outside fences, so splitting source at a
  blank-line boundary and lexing each segment independently produces
  the same AST as lexing the full source.

  If `put/2` receives text that is *not* an extension of the prior
  text (truncated or mutated), state is reset.
  """

  alias OctoPi.TUI.Components.Markdown.Lexer

  @type t :: %__MODULE__{
          text: String.t(),
          checkpoint: non_neg_integer(),
          committed: [Lexer.block()]
        }

  defstruct text: "", checkpoint: 0, committed: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec new(String.t()) :: t()
  def new(text) when is_binary(text), do: put(%__MODULE__{}, text)

  @doc """
  Update the stream with new full text. `text` is expected to be a
  prefix-extension of prior text; otherwise state is reset.
  """
  @spec put(t(), String.t()) :: t()
  def put(%__MODULE__{text: text} = s, text), do: s

  def put(%__MODULE__{text: old} = s, new_text) when is_binary(new_text) do
    if String.starts_with?(new_text, old) do
      advance(%{s | text: new_text})
    else
      put(%__MODULE__{}, new_text)
    end
  end

  @doc """
  Return the AST blocks for the current text. Committed prefix is
  returned from cache; only the unlexed tail is freshly tokenized.
  """
  @spec blocks(t()) :: [Lexer.block()]
  def blocks(%__MODULE__{text: text, checkpoint: cp, committed: c}) do
    tail_size = byte_size(text) - cp

    if tail_size == 0 do
      c
    else
      tail = binary_part(text, cp, tail_size)
      c ++ Lexer.tokenize(tail)
    end
  end

  # Find the latest paragraph boundary at or after `checkpoint` and
  # promote everything before it into committed.
  defp advance(%__MODULE__{text: text, checkpoint: cp, committed: c} = s) do
    new_cp = find_checkpoint(text, cp)

    if new_cp > cp do
      segment = binary_part(text, cp, new_cp - cp)
      new_blocks = Lexer.tokenize(segment)
      %{s | checkpoint: new_cp, committed: c ++ new_blocks}
    else
      s
    end
  end

  # Walk text from `from` to end, line by line, tracking whether we're
  # inside an open code fence. Return the byte offset of the start of
  # the line *after* the last blank line found outside a fence. If no
  # such boundary exists, return `from` unchanged.
  defp find_checkpoint(text, from) do
    suffix = binary_part(text, from, byte_size(text) - from)
    lines = String.split(suffix, "\n")
    scan_lines(lines, from, from, false, nil)
  end

  # offset: byte offset of the start of `line` within text.
  # last: byte offset of the line *after* the most recent boundary, or nil.
  defp scan_lines([], _offset, _from, _in_fence, last), do: last || 0

  defp scan_lines([_last_line], _offset, from, _in_fence, last) do
    # The final element after split has no trailing newline — incomplete
    # last line, never a boundary candidate.
    last || from
  end

  defp scan_lines([line | rest], offset, from, in_fence, last) do
    line_size = byte_size(line)
    next_offset = offset + line_size + 1

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

  defp fence_marker?(line) do
    String.match?(line, ~r/^\s{0,3}(```|~~~)/)
  end
end
