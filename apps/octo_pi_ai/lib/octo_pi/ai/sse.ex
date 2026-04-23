defmodule OctoPi.AI.SSE do
  @moduledoc """
  Incremental SSE (Server-Sent Events) decoder.

  Feed raw bytes into `decode/2` as they arrive from the HTTP client;
  the decoder buffers incomplete lines across calls and emits a list
  of `Event.t()` for each fully-assembled event. When the stream ends
  cleanly, call `finalize/1` to decode any trailing unterminated line
  and flush a pending event that was built up but not yet delimited
  by a blank line. Matches pi-mono's `iterateSseMessages` EOF
  behaviour (`anthropic.ts` L343-353): a server that closes without
  a trailing `\\n\\n` still delivers its last event.

  Line terminators `\\r`, `\\n`, and `\\r\\n` are all recognized.
  A lone `\\r` at the very end of the buffer is treated as incomplete
  and held over until the next chunk arrives, so a CRLF split across
  chunk boundaries still reads as a single line break (pi-mono's JS
  parser has a latent bug here; we fix it without changing Anthropic's
  observable behaviour, since Anthropic sends LF-only).

  Ported from `tmp/pi-mono/packages/ai/src/providers/anthropic.ts`
  L217-353, minus the `raw` scratch buffer used for error reporting
  upstream (YAGNI — add back if we ever surface parse errors).

  See `docs/port-map/anthropic.md` §3 for the porting spec.
  """

  alias OctoPi.AI.SSE.Event

  @type t :: %__MODULE__{
          buffer: binary(),
          event: String.t() | nil,
          data: [String.t()]
        }

  defstruct buffer: <<>>, event: nil, data: []

  @doc "Return a fresh decoder state."
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Feed a chunk of bytes into the decoder. Returns any SSE events
  fully assembled during this call, plus the updated state.

  `bytes` may be empty, a partial line, a single complete event,
  multiple complete events, or anything in between — the buffer
  handles it.
  """
  @spec decode(t(), binary()) :: {[Event.t()], t()}
  def decode(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    drain(%{state | buffer: state.buffer <> bytes}, [])
  end

  @doc """
  Decode any trailing unterminated line and flush any pending event
  that didn't have a blank-line delimiter. Returns any events that
  fall out, plus a reset state. Call at end-of-stream.

  Idempotent on a clean state (no buffer, no pending event/data):
  returns `{[], state}` unchanged-in-effect.
  """
  @spec finalize(t()) :: {[Event.t()], t()}
  def finalize(%__MODULE__{buffer: <<>>} = state), do: finalize_pending(state, [])

  def finalize(%__MODULE__{buffer: buffer} = state) do
    {maybe_event, state} = process_line(buffer, %{state | buffer: <<>>})
    acc = if maybe_event, do: [maybe_event], else: []
    finalize_pending(state, acc)
  end

  defp finalize_pending(state, acc) do
    {maybe_event, state} = flush(state)
    acc = if maybe_event, do: acc ++ [maybe_event], else: acc
    {acc, state}
  end

  @spec drain(t(), [Event.t()]) :: {[Event.t()], t()}
  defp drain(state, acc) do
    case find_line_break(state.buffer) do
      :none ->
        {Enum.reverse(acc), state}

      {line, rest} ->
        {maybe_event, state} = process_line(line, %{state | buffer: rest})
        acc = if maybe_event, do: [maybe_event | acc], else: acc
        drain(state, acc)
    end
  end

  @spec find_line_break(binary()) :: :none | {binary(), binary()}
  defp find_line_break(buffer), do: scan(buffer, <<>>)

  defp scan(<<"\r\n", rest::binary>>, acc), do: {acc, rest}
  defp scan(<<"\r">>, _acc), do: :none
  defp scan(<<"\r", rest::binary>>, acc), do: {acc, rest}
  defp scan(<<"\n", rest::binary>>, acc), do: {acc, rest}
  defp scan(<<b, rest::binary>>, acc), do: scan(rest, <<acc::binary, b>>)
  defp scan(<<>>, _acc), do: :none

  @spec process_line(binary(), t()) :: {Event.t() | nil, t()}
  defp process_line(<<>>, state), do: flush(state)
  defp process_line(<<":", _::binary>>, state), do: {nil, state}

  defp process_line(line, state) do
    {field, value} = split_field(line)
    {nil, apply_field(state, field, value)}
  end

  @spec split_field(binary()) :: {binary(), binary()}
  defp split_field(line) do
    case :binary.split(line, ":") do
      [whole] -> {whole, ""}
      [field, value] -> {field, strip_leading_space(value)}
    end
  end

  @spec strip_leading_space(binary()) :: binary()
  defp strip_leading_space(<<" ", rest::binary>>), do: rest
  defp strip_leading_space(value), do: value

  @spec apply_field(t(), binary(), binary()) :: t()
  defp apply_field(state, "event", value), do: %{state | event: value}
  defp apply_field(state, "data", value), do: %{state | data: [value | state.data]}
  defp apply_field(state, _other, _value), do: state

  @spec flush(t()) :: {Event.t() | nil, t()}
  defp flush(%__MODULE__{event: nil, data: []} = state), do: {nil, state}

  defp flush(state) do
    event = %Event{
      event: state.event,
      data: state.data |> Enum.reverse() |> Enum.join("\n")
    }

    {event, %{state | event: nil, data: []}}
  end
end
