defmodule OctoPi.AI.Providers.OpenAI.Decoder do
  @moduledoc """
  Pure state machine that converts OpenAI `ChatCompletionChunk` deltas
  into the canonical `OctoPi.AI.Event` union. Mirrors the Anthropic
  decoder's API: `new/1`, `handle/2`, `finalize/1`, `error/3`.

  Unlike Anthropic's typed event protocol, OpenAI sends everything on
  a flat `choices[0].delta` object — text, reasoning, and tool calls
  arrive as optional fields on the same delta.

  Content is stored in reverse order during streaming for O(1) head
  updates (same pattern as the Anthropic decoder). `present/1` flips
  to forward order for every emitted event.

  Extracted from `openai-completions.ts` L198-391.
  """

  alias OctoPi.AI.{Content, Event, Message, Model, PartialJson, ToolCall, Usage}

  defmodule State do
    @moduledoc false

    @type block_type :: :text | :thinking | {:tool_call, non_neg_integer() | nil}

    @type t :: %__MODULE__{
            model: Model.t(),
            message: Message.Assistant.t(),
            content_count: non_neg_integer(),
            current_block: block_type() | nil,
            partial_args: %{non_neg_integer() => binary()},
            reasoning_field: String.t() | nil
          }

    defstruct [
      :model,
      :message,
      content_count: 0,
      current_block: nil,
      partial_args: %{},
      reasoning_field: nil
    ]
  end

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

  @spec handle(State.t(), map()) :: {[Event.t()], State.t()}
  def handle(state, %{"choices" => choices} = chunk) when is_list(choices) do
    state = capture_response_id(state, chunk)

    choice = List.first(choices)

    state =
      state
      |> parse_usage(chunk, choice)
      |> parse_finish_reason(choice)

    delta = (choice && choice["delta"]) || %{}

    {events, state} =
      state
      |> handle_text(delta)
      |> handle_reasoning(delta)
      |> handle_tool_calls(delta)

    {events, state}
  end

  def handle(state, _unknown), do: {[], state}

  @spec finalize(State.t()) :: Event.Done.t() | Event.Error.t()
  def finalize(state) do
    {finish_events, state} = finish_current_block(state)
    final = present(state.message)

    terminal =
      case final.stop_reason do
        reason when reason in [:stop, :length, :tool_use] ->
          %Event.Done{reason: reason, message: final}

        :error ->
          %Event.Error{reason: :error, message: final}

        :aborted ->
          %Event.Error{reason: :aborted, message: final}

        nil ->
          %Event.Done{reason: :stop, message: final}
      end

    # finish_events are consumed internally; terminal is the only emitted event
    _ = finish_events
    terminal
  end

  @spec message(State.t()) :: Message.Assistant.t()
  def message(%State{message: msg}), do: present(msg)

  @spec error(State.t(), binary(), :error | :aborted) :: {Event.Error.t(), State.t()}
  def error(state, reason_message, reason \\ :error)
      when reason in [:error, :aborted] and is_binary(reason_message) do
    message = %{state.message | stop_reason: reason, error_message: reason_message}
    {%Event.Error{reason: reason, message: present(message)}, %{state | message: message}}
  end

  # --- internals ---

  defp present(%Message.Assistant{content: rev} = msg) do
    %{msg | content: :lists.reverse(rev)}
  end

  defp capture_response_id(%State{message: %{response_id: nil}} = state, %{"id" => id})
       when is_binary(id) do
    %{state | message: %{state.message | response_id: id}}
  end

  defp capture_response_id(state, _chunk), do: state

  # --- usage ---

  defp parse_usage(state, %{"usage" => usage}, _choice) when is_map(usage) do
    apply_usage(state, usage)
  end

  defp parse_usage(state, _chunk, %{"usage" => usage}) when is_map(usage) do
    apply_usage(state, usage)
  end

  defp parse_usage(state, _chunk, _choice), do: state

  defp apply_usage(state, raw) do
    prompt_tokens = raw["prompt_tokens"] || 0
    reported_cached = get_in(raw, ["prompt_tokens_details", "cached_tokens"]) || 0
    cache_write = get_in(raw, ["prompt_tokens_details", "cache_write_tokens"]) || 0
    reasoning_tokens = get_in(raw, ["completion_tokens_details", "reasoning_tokens"]) || 0

    cache_read =
      if cache_write > 0,
        do: max(0, reported_cached - cache_write),
        else: reported_cached

    input = max(0, prompt_tokens - cache_read - cache_write)
    output = (raw["completion_tokens"] || 0) + reasoning_tokens

    usage =
      %Usage{
        input: input,
        output: output,
        cache_read: cache_read,
        cache_write: cache_write,
        total_tokens: input + output + cache_read + cache_write
      }
      |> then(&Model.calculate_cost(state.model, &1))

    %{state | message: %{state.message | usage: usage}}
  end

  # --- finish reason ---

  defp parse_finish_reason(state, %{"finish_reason" => reason}) when is_binary(reason) do
    {stop_reason, error_message} = map_stop_reason(reason)
    message = %{state.message | stop_reason: stop_reason}
    message = if error_message, do: %{message | error_message: error_message}, else: message
    %{state | message: message}
  end

  defp parse_finish_reason(state, _choice), do: state

  defp map_stop_reason("stop"), do: {:stop, nil}
  defp map_stop_reason("end"), do: {:stop, nil}
  defp map_stop_reason("length"), do: {:length, nil}
  defp map_stop_reason("function_call"), do: {:tool_use, nil}
  defp map_stop_reason("tool_calls"), do: {:tool_use, nil}
  defp map_stop_reason("content_filter"), do: {:error, "Provider finish_reason: content_filter"}
  defp map_stop_reason("network_error"), do: {:error, "Provider finish_reason: network_error"}
  defp map_stop_reason(other), do: {:error, "Provider finish_reason: #{other}"}

  # --- text ---

  defp handle_text({events, state}, delta), do: handle_text_impl(events, state, delta)
  defp handle_text(state, delta), do: handle_text_impl([], state, delta)

  defp handle_text_impl(events, state, %{"content" => content})
       when is_binary(content) and content != "" do
    {finish_events, state} =
      if state.current_block != :text do
        {fe, st} = finish_current_block(state)
        st = open_block(st, %Content.Text{text: ""}, :text)
        start_ev = %Event.TextStart{content_index: st.content_count - 1, partial: present(st.message)}
        {fe ++ [start_ev], st}
      else
        {[], state}
      end

    state = update_head(state, fn %Content.Text{text: t} = b -> %{b | text: t <> content} end)
    delta_ev = %Event.TextDelta{content_index: state.content_count - 1, delta: content, partial: present(state.message)}

    {events ++ finish_events ++ [delta_ev], state}
  end

  defp handle_text_impl(events, state, _delta), do: {events, state}

  # --- reasoning ---

  @reasoning_fields ["reasoning_content", "reasoning", "reasoning_text"]

  defp handle_reasoning({events, state}, delta) do
    case find_reasoning(delta, state) do
      {field, value} ->
        {finish_events, state} =
          if state.current_block != :thinking do
            {fe, st} = finish_current_block(state)
            st = %{st | reasoning_field: field}
            st = open_block(st, %Content.Thinking{thinking: "", signature: field}, :thinking)
            start_ev = %Event.ThinkingStart{content_index: st.content_count - 1, partial: present(st.message)}
            {fe ++ [start_ev], st}
          else
            {[], state}
          end

        state =
          update_head(state, fn %Content.Thinking{thinking: t} = b ->
            %{b | thinking: t <> value}
          end)
        delta_ev = %Event.ThinkingDelta{
          content_index: state.content_count - 1,
          delta: value,
          partial: present(state.message)
        }

        {events ++ finish_events ++ [delta_ev], state}

      nil ->
        {events, state}
    end
  end

  defp find_reasoning(delta, _state) do
    Enum.find_value(@reasoning_fields, fn field ->
      value = delta[field]

      if is_binary(value) and value != "" do
        {field, value}
      end
    end)
  end

  # --- tool calls ---

  defp handle_tool_calls({events, state}, %{"tool_calls" => tool_calls})
       when is_list(tool_calls) do
    Enum.reduce(tool_calls, {events, state}, fn tc_delta, {evs, st} ->
      handle_one_tool_call(evs, st, tc_delta)
    end)
  end

  defp handle_tool_calls({events, state}, _delta), do: {events, state}

  defp handle_one_tool_call(events, state, tc_delta) do
    {finish_events, state} = maybe_open_tool_block(state, tc_delta)

    position = state.content_count - 1

    state =
      state
      |> maybe_update_tc_id(tc_delta)
      |> maybe_update_tc_name(tc_delta)
      |> accumulate_tc_args(tc_delta, position)

    delta_str = get_in(tc_delta, ["function", "arguments"]) || ""
    delta_ev = %Event.ToolCallDelta{content_index: position, delta: delta_str, partial: present(state.message)}

    {events ++ finish_events ++ [delta_ev], state}
  end

  defp maybe_open_tool_block(state, tc_delta) do
    if same_tool?(state, tc_delta) do
      {[], state}
    else
      {fe, st} = finish_current_block(state)

      tc = %ToolCall{
        id: tc_delta["id"] || "",
        name: get_in(tc_delta, ["function", "name"]) || "",
        arguments: %{}
      }

      st = open_block(st, tc, {:tool_call, tc_delta["index"]})
      start_ev = %Event.ToolCallStart{content_index: st.content_count - 1, partial: present(st.message)}
      {fe ++ [start_ev], st}
    end
  end

  defp same_tool?(%State{current_block: {:tool_call, idx}}, %{"index" => stream_index})
       when stream_index != nil do
    idx == stream_index
  end

  defp same_tool?(%State{current_block: {:tool_call, _}, message: %{content: [%ToolCall{id: id} | _]}}, %{
         "id" => delta_id
       })
       when is_binary(delta_id) and delta_id != "" do
    id == delta_id
  end

  defp same_tool?(_state, _tc_delta), do: false

  defp maybe_update_tc_id(state, %{"id" => id}) when is_binary(id) and id != "" do
    update_head(state, fn
      %ToolCall{id: ""} = tc -> %{tc | id: id}
      tc -> tc
    end)
  end

  defp maybe_update_tc_id(state, _), do: state

  defp maybe_update_tc_name(state, %{"function" => %{"name" => name}})
       when is_binary(name) and name != "" do
    update_head(state, fn
      %ToolCall{name: ""} = tc -> %{tc | name: name}
      tc -> tc
    end)
  end

  defp maybe_update_tc_name(state, _), do: state

  defp accumulate_tc_args(state, %{"function" => %{"arguments" => args}}, position)
       when is_binary(args) and args != "" do
    accumulated = Map.get(state.partial_args, position, "") <> args
    parsed = PartialJson.parse_streaming(accumulated)

    state = update_head(state, fn %ToolCall{} = tc -> %{tc | arguments: parsed} end)
    %{state | partial_args: Map.put(state.partial_args, position, accumulated)}
  end

  defp accumulate_tc_args(state, _tc_delta, _position), do: state

  # --- block lifecycle ---

  defp open_block(state, block, block_type) do
    block = stamp_index(block, state.content_count)
    message = %{state.message | content: [block | state.message.content]}

    %{state |
      message: message,
      content_count: state.content_count + 1,
      current_block: block_type}
  end

  defp stamp_index(%Content.Text{} = b, idx), do: %{b | content_index: idx}
  defp stamp_index(%Content.Thinking{} = b, idx), do: %{b | content_index: idx}
  defp stamp_index(other, _idx), do: other

  defp finish_current_block(%State{current_block: nil} = state), do: {[], state}

  defp finish_current_block(%State{current_block: :text} = state) do
    position = state.content_count - 1
    block = hd(state.message.content)

    event = %Event.TextEnd{
      content_index: position,
      content: block.text,
      partial: present(state.message)
    }

    {[event], %{state | current_block: nil}}
  end

  defp finish_current_block(%State{current_block: :thinking} = state) do
    position = state.content_count - 1
    block = hd(state.message.content)

    event = %Event.ThinkingEnd{
      content_index: position,
      content: block.thinking,
      partial: present(state.message)
    }

    {[event], %{state | current_block: nil}}
  end

  defp finish_current_block(%State{current_block: {:tool_call, _}} = state) do
    position = state.content_count - 1
    accumulated = Map.get(state.partial_args, position, "")

    finalized =
      if accumulated != "" do
        update_head(state, fn %ToolCall{} = tc ->
          %{tc | arguments: PartialJson.parse_streaming(accumulated)}
        end)
      else
        state
      end

    block = hd(finalized.message.content)

    event = %Event.ToolCallEnd{
      content_index: position,
      tool_call: block,
      partial: present(finalized.message)
    }

    {[event], %{finalized | current_block: nil, partial_args: Map.delete(finalized.partial_args, position)}}
  end

  defp update_head(%State{message: %{content: [head | rest]} = msg} = state, fun) do
    %{state | message: %{msg | content: [fun.(head) | rest]}}
  end
end
