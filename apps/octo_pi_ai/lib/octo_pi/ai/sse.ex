defmodule OctoPi.AI.SSE do
  @moduledoc """
  Incremental SSE (Server-Sent Events) decoder.

  Feed raw bytes into `decode/2` as they arrive from the HTTP client;
  the decoder buffers incomplete lines across calls and emits a list
  of `Event.t()` for each fully-assembled event. State is opaque —
  discard it when the stream ends (any trailing incomplete event in
  the buffer is silently dropped, matching pi-mono's semantics).

  Line terminators `\\r`, `\\n`, and `\\r\\n` are all recognized.
  A lone `\\r` at the very end of the buffer is treated as incomplete
  and held over until the next chunk arrives, so a CRLF split across
  chunk boundaries still reads as a single line break (pi-mono's JS
  parser has a latent bug here; we fix it without changing Anthropic's
  observable behaviour, since Anthropic sends LF-only).

  Ported from `tmp/pi-mono/packages/ai/src/providers/anthropic.ts`
  L217-298, minus the `raw` scratch buffer used for error reporting
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
