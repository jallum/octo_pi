defmodule OctoPi.AI.Providers.Anthropic.Decoder do
  @moduledoc """
  Pure state machine that converts Anthropic's SSE events (decoded
  into plain Elixir maps with string keys) into the canonical
  `OctoPi.AI.Event` union.

  Call `new/1` once when a stream opens to get the initial `:start`
  event and an opaque decoder state. Feed each Anthropic SSE event
  (the `data` field, JSON-decoded) into `handle/2` to get zero or
  more canonical events. At end-of-stream call `finalize/1` to get
  the terminal `:done` or `:error` event.

  Ported from `tmp/pi-mono/packages/ai/src/providers/anthropic.ts`
  L451-633. See `docs/port-map/anthropic.md` §6.
  """

  alias OctoPi.AI.{
    Content,
    Event,
    Message,
    Model,
    PartialJson,
    ToolCall,
    Usage
  }

  defmodule State do
    @moduledoc "Opaque decoder state — do not pattern-match externally."

    alias OctoPi.AI.{Message, Model}

    @type t :: %__MODULE__{
            model: Model.t(),
            message: Message.Assistant.t(),
            index_map: %{non_neg_integer() => non_neg_integer()},
            partial_json: %{non_neg_integer() => binary()}
          }

    defstruct [:model, :message, index_map: %{}, partial_json: %{}]
  end

  @doc """
  Initialize a decoder for a fresh Anthropic stream. Returns the
  `:start` canonical event (which carries an empty partial message)
  and the initial state.
  """
  @spec new(Model.t()) :: {Event.Start.t(), State.t()}
  def new(%Model{} = model) do
    message = %Message.Assistant{
      api: model.api,
      provider: model.provider,
      model: model.id,
      timestamp: :os.system_time(:millisecond),
      usage: %Usage{}
    }

    state = %State{model: model, message: message}
    {%Event.Start{partial: message}, state}
  end

  @doc """
  Handle one decoded Anthropic SSE event. Returns any canonical
  events triggered by this event and the updated state.

  Unknown event types are silently ignored so new Anthropic event
  types don't break the stream.
  """
  @spec handle(State.t(), map()) :: {[Event.t()], State.t()}
  def handle(state, event)

  def handle(state, %{"type" => "message_start", "message" => msg}) do
    usage = extract_usage(msg["usage"] || %{})
    message = %{state.message | response_id: msg["id"], usage: usage}
    {[], %{state | message: message}}
  end

  def handle(
        state,
        %{
          "type" => "content_block_start",
          "index" => idx,
          "content_block" => block
        }
      ) do
    content_item = build_content_item(block)
    position = length(state.message.content)
    message = %{state.message | content: state.message.content ++ [content_item]}
    new_state = %{state | message: message, index_map: Map.put(state.index_map, idx, position)}
    {[start_event_for(block["type"], position, message)], new_state}
  end

  def handle(state, %{"type" => "content_block_delta", "index" => idx, "delta" => delta}) do
    case Map.fetch(state.index_map, idx) do
      {:ok, position} -> apply_delta(delta, position, state)
      :error -> {[], state}
    end
  end

  def handle(state, %{"type" => "content_block_stop", "index" => idx}) do
    case Map.fetch(state.index_map, idx) do
      {:ok, position} -> emit_end(position, state)
      :error -> {[], state}
    end
  end

  def handle(state, %{"type" => "message_delta", "delta" => delta} = event) do
    usage_delta = event["usage"] || %{}

    message =
      state.message
      |> maybe_set_stop_reason(delta["stop_reason"])
      |> merge_usage(usage_delta)

    {[], %{state | message: message}}
  end

  def handle(state, %{"type" => "message_stop"}), do: {[], state}

  def handle(state, _unknown), do: {[], state}

  @doc """
  Produce the terminal event for a stream that ended cleanly.
  Returns `Event.Done` for a successful stop reason, or `Event.Error`
  if the message ended in error/aborted or never received a stop
  reason at all.
  """
  @spec finalize(State.t()) :: Event.Done.t() | Event.Error.t()
  def finalize(state) do
    case state.message.stop_reason do
      reason when reason in [:stop, :length, :tool_use] ->
        %Event.Done{reason: reason, message: state.message}

      reason when reason in [:error, :aborted] ->
        %Event.Error{reason: reason, message: state.message}

      nil ->
        msg = %{
          state.message
          | stop_reason: :error,
            error_message: "stream ended without stop_reason"
        }

        %Event.Error{reason: :error, message: msg}
    end
  end

  @doc """
  Convenience for surfacing a transport-layer failure as a canonical
  error event. Sets `stop_reason` and `error_message` on the partial
  message and returns the matching `Event.Error`.
  """
  @spec error(State.t(), binary(), :error | :aborted) :: {Event.Error.t(), State.t()}
  def error(state, reason_message, reason \\ :error)
      when reason in [:error, :aborted] and is_binary(reason_message) do
    message = %{state.message | stop_reason: reason, error_message: reason_message}
    {%Event.Error{reason: reason, message: message}, %{state | message: message}}
  end

  # --- helpers ---

  @spec extract_usage(map()) :: Usage.t()
  defp extract_usage(usage) do
    input = usage["input_tokens"] || 0
    output = usage["output_tokens"] || 0
    cache_read = usage["cache_read_input_tokens"] || 0
    cache_write = usage["cache_creation_input_tokens"] || 0

    %Usage{
      input: input,
      output: output,
      cache_read: cache_read,
      cache_write: cache_write,
      total_tokens: input + output + cache_read + cache_write
    }
  end

  @spec build_content_item(map()) ::
          Content.Text.t() | Content.Thinking.t() | ToolCall.t()
  defp build_content_item(%{"type" => "text"}), do: %Content.Text{text: ""}

  defp build_content_item(%{"type" => "thinking"}),
    do: %Content.Thinking{thinking: "", signature: ""}

  defp build_content_item(%{"type" => "redacted_thinking"} = block) do
    %Content.Thinking{
      thinking: "[Reasoning redacted]",
      signature: block["data"] || "",
      redacted?: true
    }
  end

  defp build_content_item(%{"type" => "tool_use"} = block) do
    %ToolCall{
      id: block["id"],
      name: block["name"],
      arguments: block["input"] || %{}
    }
  end

  @spec start_event_for(binary(), non_neg_integer(), Message.Assistant.t()) ::
          Event.TextStart.t() | Event.ThinkingStart.t() | Event.ToolCallStart.t()
  defp start_event_for("text", pos, partial),
    do: %Event.TextStart{content_index: pos, partial: partial}

  defp start_event_for(type, pos, partial) when type in ["thinking", "redacted_thinking"],
    do: %Event.ThinkingStart{content_index: pos, partial: partial}

  defp start_event_for("tool_use", pos, partial),
    do: %Event.ToolCallStart{content_index: pos, partial: partial}

  @spec apply_delta(map(), non_neg_integer(), State.t()) :: {[Event.t()], State.t()}
  defp apply_delta(%{"type" => "text_delta", "text" => text}, position, state) do
    content =
      List.update_at(state.message.content, position, fn %Content.Text{text: existing} = block ->
        %{block | text: existing <> text}
      end)

    message = %{state.message | content: content}

    {[%Event.TextDelta{content_index: position, delta: text, partial: message}],
     %{state | message: message}}
  end

  defp apply_delta(%{"type" => "thinking_delta", "thinking" => chunk}, position, state) do
    content =
      List.update_at(state.message.content, position, fn
        %Content.Thinking{thinking: existing} = block ->
          %{block | thinking: existing <> chunk}
      end)

    message = %{state.message | content: content}

    {[%Event.ThinkingDelta{content_index: position, delta: chunk, partial: message}],
     %{state | message: message}}
  end

  defp apply_delta(%{"type" => "signature_delta", "signature" => sig}, position, state) do
    content =
      List.update_at(state.message.content, position, fn
        %Content.Thinking{signature: existing} = block ->
          %{block | signature: (existing || "") <> sig}
      end)

    {[], %{state | message: %{state.message | content: content}}}
  end

  defp apply_delta(%{"type" => "input_json_delta", "partial_json" => fragment}, position, state) do
    accumulated = Map.get(state.partial_json, position, "") <> fragment
    arguments = PartialJson.parse_streaming(accumulated)

    content =
      List.update_at(state.message.content, position, fn %ToolCall{} = block ->
        %{block | arguments: arguments}
      end)

    message = %{state.message | content: content}

    {[%Event.ToolCallDelta{content_index: position, delta: fragment, partial: message}],
     %{state | message: message, partial_json: Map.put(state.partial_json, position, accumulated)}}
  end

  defp apply_delta(_other, _position, state), do: {[], state}

  @spec emit_end(non_neg_integer(), State.t()) :: {[Event.t()], State.t()}
  defp emit_end(position, state) do
    case Enum.at(state.message.content, position) do
      %Content.Text{} = block ->
        {[
           %Event.TextEnd{
             content_index: position,
             content: block.text,
             partial: state.message
           }
         ], state}

      %Content.Thinking{} = block ->
        {[
           %Event.ThinkingEnd{
             content_index: position,
             content: block.thinking,
             partial: state.message
           }
         ], state}

      %ToolCall{} = block ->
        partial_json = Map.get(state.partial_json, position, "")

        finalized =
          if partial_json == "",
            do: block,
            else: %{block | arguments: PartialJson.parse_streaming(partial_json)}

        content = List.replace_at(state.message.content, position, finalized)
        message = %{state.message | content: content}

        {[
           %Event.ToolCallEnd{
             content_index: position,
             tool_call: finalized,
             partial: message
           }
         ], %{state | message: message, partial_json: Map.delete(state.partial_json, position)}}

      nil ->
        {[], state}
    end
  end

  @spec maybe_set_stop_reason(Message.Assistant.t(), binary() | nil) :: Message.Assistant.t()
  defp maybe_set_stop_reason(message, nil), do: message

  defp maybe_set_stop_reason(message, reason),
    do: %{message | stop_reason: map_stop_reason(reason)}

  @spec map_stop_reason(binary()) :: Message.Assistant.stop_reason()
  defp map_stop_reason("end_turn"), do: :stop
  defp map_stop_reason("stop_sequence"), do: :stop
  defp map_stop_reason("pause_turn"), do: :stop
  defp map_stop_reason("max_tokens"), do: :length
  defp map_stop_reason("tool_use"), do: :tool_use
  defp map_stop_reason("refusal"), do: :error
  defp map_stop_reason("sensitive"), do: :error

  defp map_stop_reason(other),
    do: raise(ArgumentError, "unknown Anthropic stop_reason: #{inspect(other)}")

  @spec merge_usage(Message.Assistant.t(), map()) :: Message.Assistant.t()
  defp merge_usage(message, usage) do
    current = message.usage

    updated = %Usage{
      input: usage["input_tokens"] || current.input,
      output: usage["output_tokens"] || current.output,
      cache_read: usage["cache_read_input_tokens"] || current.cache_read,
      cache_write: usage["cache_creation_input_tokens"] || current.cache_write
    }

    total = updated.input + updated.output + updated.cache_read + updated.cache_write
    %{message | usage: %{updated | total_tokens: total}}
  end
end
