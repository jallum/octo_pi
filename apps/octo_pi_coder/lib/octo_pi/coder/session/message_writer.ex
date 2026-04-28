defmodule OctoPi.Coder.Session.MessageWriter do
  @moduledoc """
  Convert `OctoPi.AI.Message.*` structs to the string-keyed JSON maps
  stored in `Entry.Message.message`.

  In the upstream TypeScript the same JavaScript object is used from
  provider response through to `JSON.stringify` in the session store —
  no conversion is needed. In Elixir we have typed structs, so this
  module is the explicit boundary.

  Wire format mirrors the upstream JSONL schema (session-manager.ts,
  messages.ts in pi-mono).
  """

  alias OctoPi.AI.Content.{Image, Text, Thinking}
  alias OctoPi.AI.Message.{Assistant, ToolResult, User}
  alias OctoPi.AI.ToolCall

  @doc "Convert a `%User{}` to an Entry.Message.message map."
  @spec from_user(User.t()) :: map()
  def from_user(%User{content: content, timestamp: ts}) do
    %{
      "role" => "user",
      "content" => user_content(content),
      "timestamp" => ts
    }
  end

  @doc "Convert a `%Assistant{}` to an Entry.Message.message map."
  @spec from_assistant(Assistant.t()) :: map()
  def from_assistant(%Assistant{} = msg) do
    base = %{
      "role" => "assistant",
      "content" => assistant_content(msg.content),
      "api" => to_string(msg.api),
      "provider" => to_string(msg.provider),
      "model" => msg.model,
      "usage" => usage_map(msg.usage),
      "stopReason" => stop_reason_string(msg.stop_reason),
      "timestamp" => msg.timestamp
    }

    base
    |> maybe_put("responseId", msg.response_id)
    |> maybe_put("errorMessage", msg.error_message)
  end

  @doc "Convert a `%ToolResult{}` to an Entry.Message.message map."
  @spec from_tool_result(ToolResult.t()) :: map()
  def from_tool_result(%ToolResult{} = r) do
    %{
      "role" => "toolResult",
      "tool_call_id" => r.tool_call_id,
      "tool_name" => r.tool_name,
      "content" => user_content(r.content),
      "is_error" => r.is_error?,
      "timestamp" => r.timestamp
    }
  end

  # ---- content block serialization ----------------------------------------

  defp user_content(text) when is_binary(text), do: [%{"type" => "text", "text" => text}]
  defp user_content(blocks) when is_list(blocks), do: Enum.map(blocks, &user_block/1)

  defp user_block(%Text{text: t}), do: %{"type" => "text", "text" => t}

  defp user_block(%Image{data: d, mime_type: mt}),
    do: %{"type" => "image", "data" => d, "mimeType" => mt}

  defp assistant_content(blocks), do: Enum.flat_map(blocks, &assistant_block/1)

  defp assistant_block(%Text{text: t}), do: [%{"type" => "text", "text" => t}]

  defp assistant_block(%Thinking{thinking: t, signature: sig, redacted?: false}),
    do: [%{"type" => "thinking", "thinking" => t, "thinkingSignature" => sig}]

  defp assistant_block(%Thinking{signature: sig, redacted?: true}),
    do: [%{"type" => "thinking", "thinking" => "[Reasoning redacted]", "thinkingSignature" => sig, "redacted" => true}]

  defp assistant_block(%ToolCall{id: id, name: name, arguments: args}),
    do: [%{"type" => "tool_use", "id" => id, "name" => name, "input" => args}]

  defp assistant_block(_), do: []

  # ---- usage / cost -------------------------------------------------------

  defp usage_map(%{input: i, output: o, cache_read: cr, cache_write: cw, total_tokens: tt, cost: cost}) do
    %{
      "input" => i,
      "output" => o,
      "cacheRead" => cr,
      "cacheWrite" => cw,
      "totalTokens" => tt,
      "cost" => cost_map(cost)
    }
  end

  defp usage_map(_), do: %{"input" => 0, "output" => 0, "cacheRead" => 0, "cacheWrite" => 0}

  defp cost_map(%{input: i, output: o, cache_read: cr, cache_write: cw, total: t}) do
    %{"input" => i, "output" => o, "cacheRead" => cr, "cacheWrite" => cw, "total" => t}
  end

  defp cost_map(_), do: %{"input" => 0.0, "output" => 0.0, "cacheRead" => 0.0, "cacheWrite" => 0.0, "total" => 0.0}

  # ---- helpers ------------------------------------------------------------

  defp stop_reason_string(nil), do: nil
  defp stop_reason_string(reason), do: to_string(reason)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
