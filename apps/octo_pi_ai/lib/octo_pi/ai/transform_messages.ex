defmodule OctoPi.AI.TransformMessages do
  @moduledoc """
  Cross-provider message normalization. Handles image downgrade for
  non-vision models, thinking block coercion for cross-model replay,
  tool-call ID normalization, orphaned tool-call synthesis, and
  errored/aborted message skipping.

  Both Anthropic and OpenAI providers call this before converting
  messages to their wire format.

  Ported from `transform-messages.ts` L64-220.
  """

  alias OctoPi.AI.{Content, Message, Model, ToolCall}

  @type normalize_fn :: (String.t(), Model.t(), Message.Assistant.t() -> String.t())

  @spec transform([Message.t()], Model.t(), normalize_fn() | nil) :: [Message.t()]
  def transform(messages, %Model{} = model, normalize_tool_call_id \\ nil) do
    tool_call_id_map = %{}

    messages
    |> downgrade_images(model)
    |> transform_pass(model, normalize_tool_call_id, tool_call_id_map)
    |> synthesize_orphaned_results()
  end

  # --- image downgrade ---

  defp downgrade_images(messages, %Model{input: input}) do
    if :image in input do
      messages
    else
      Enum.map(messages, &downgrade_message_images/1)
    end
  end

  defp downgrade_message_images(%Message.User{content: blocks} = msg) when is_list(blocks) do
    %{msg | content: replace_images(blocks, "(image omitted: model does not support images)")}
  end

  defp downgrade_message_images(%Message.ToolResult{content: blocks} = msg) do
    %{msg | content: replace_images(blocks, "(tool image omitted: model does not support images)")}
  end

  defp downgrade_message_images(msg), do: msg

  defp replace_images(blocks, placeholder) do
    {result_rev, _prev_was_placeholder} =
      Enum.reduce(blocks, {[], false}, fn
        %Content.Image{}, {acc, true} ->
          {acc, true}

        %Content.Image{}, {acc, false} ->
          {[%Content.Text{text: placeholder} | acc], true}

        %Content.Text{text: text} = block, {acc, _} ->
          {[block | acc], text == placeholder}

        block, {acc, _} ->
          {[block | acc], false}
      end)

    Enum.reverse(result_rev)
  end

  # --- first pass: transform assistant messages ---

  defp transform_pass(messages, model, normalize_fn, id_map) do
    {transformed, _id_map} =
      Enum.reduce(messages, {[], id_map}, fn msg, {acc, map} ->
        case msg do
          %Message.User{} ->
            {[msg | acc], map}

          %Message.ToolResult{} = tr ->
            normalized_id = Map.get(map, tr.tool_call_id, tr.tool_call_id)
            updated = if normalized_id != tr.tool_call_id, do: %{tr | tool_call_id: normalized_id}, else: tr
            {[updated | acc], map}

          %Message.Assistant{} = asst ->
            transform_assistant(asst, model, normalize_fn, acc, map)
        end
      end)

    Enum.reverse(transformed)
  end

  defp transform_assistant(%Message.Assistant{stop_reason: reason}, _model, _norm_fn, acc, map)
       when reason in [:error, :aborted] do
    {acc, map}
  end

  defp transform_assistant(%Message.Assistant{} = asst, model, normalize_fn, acc, map) do
    same_model? =
      asst.provider == model.provider and
        asst.api == model.api and
        asst.model == model.id

    {content, map} = transform_content(asst.content, same_model?, model, asst, normalize_fn, map)
    {[%{asst | content: content} | acc], map}
  end

  defp transform_content(blocks, same_model?, model, source, normalize_fn, id_map) do
    {content_rev, id_map} =
      Enum.reduce(blocks, {[], id_map}, fn block, {acc, map} ->
        case transform_block(block, same_model?, model, source, normalize_fn, map) do
          {:keep, transformed, map} -> {[transformed | acc], map}
          {:drop, map} -> {acc, map}
        end
      end)

    {Enum.reverse(content_rev), id_map}
  end

  defp transform_block(%Content.Thinking{redacted?: true}, true, _model, _source, _norm, map),
    do: {:keep, %Content.Thinking{redacted?: true}, map}

  defp transform_block(%Content.Thinking{redacted?: true}, false, _model, _source, _norm, map),
    do: {:drop, map}

  defp transform_block(%Content.Thinking{signature: sig} = block, true, _model, _source, _norm, map)
       when is_binary(sig) and sig != "" do
    {:keep, block, map}
  end

  defp transform_block(%Content.Thinking{thinking: thinking}, _same?, _model, _source, _norm, map)
       when thinking == "" or thinking == nil do
    {:drop, map}
  end

  defp transform_block(%Content.Thinking{} = block, true, _model, _source, _norm, map),
    do: {:keep, block, map}

  defp transform_block(%Content.Thinking{thinking: thinking}, false, _model, _source, _norm, map),
    do: {:keep, %Content.Text{text: thinking}, map}

  defp transform_block(%Content.Text{} = block, true, _model, _source, _norm, map),
    do: {:keep, block, map}

  defp transform_block(%Content.Text{text: text}, false, _model, _source, _norm, map),
    do: {:keep, %Content.Text{text: text}, map}

  defp transform_block(%ToolCall{} = tc, true, _model, _source, _norm, map),
    do: {:keep, tc, map}

  defp transform_block(%ToolCall{} = tc, false, model, source, normalize_fn, map) do
    tc = %{tc | thought_signature: nil}

    if normalize_fn do
      normalized_id = normalize_fn.(tc.id, model, source)

      if normalized_id != tc.id do
        {:keep, %{tc | id: normalized_id}, Map.put(map, tc.id, normalized_id)}
      else
        {:keep, tc, map}
      end
    else
      {:keep, tc, map}
    end
  end

  # --- orphaned tool call synthesis ---

  defp synthesize_orphaned_results(messages) do
    {result, pending, existing_ids} =
      Enum.reduce(messages, {[], [], MapSet.new()}, fn msg, {acc, pending, existing} ->
        case msg do
          %Message.Assistant{} = asst ->
            acc = flush_pending(acc, pending, existing)
            tool_calls = Enum.filter(asst.content, &match?(%ToolCall{}, &1))

            if tool_calls == [] do
              {[asst | acc], [], MapSet.new()}
            else
              {[asst | acc], tool_calls, MapSet.new()}
            end

          %Message.ToolResult{} = tr ->
            {[tr | acc], pending, MapSet.put(existing, tr.tool_call_id)}

          %Message.User{} = user ->
            acc = flush_pending(acc, pending, existing)
            {[user | acc], [], MapSet.new()}
        end
      end)

    result
    |> flush_pending(pending, existing_ids)
    |> Enum.reverse()
  end

  defp flush_pending(acc, [], _existing), do: acc

  defp flush_pending(acc, pending, existing) do
    Enum.reduce(pending, acc, fn %ToolCall{} = tc, acc ->
      if MapSet.member?(existing, tc.id) do
        acc
      else
        synthetic = %Message.ToolResult{
          tool_call_id: tc.id,
          tool_name: tc.name,
          content: [%Content.Text{text: "No result provided"}],
          is_error?: true,
          timestamp: :os.system_time(:millisecond)
        }

        [synthetic | acc]
      end
    end)
  end
end
