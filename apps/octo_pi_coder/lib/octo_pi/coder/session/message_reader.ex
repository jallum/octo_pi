defmodule OctoPi.Coder.Session.MessageReader do
  @moduledoc """
  Convert the string-keyed JSON maps stored in `Entry.Message.message`
  back to `OctoPi.AI.Message.*` typed structs.

  This is the inverse of `MessageWriter` — used when building the LLM
  context from a loaded session (resumption, compaction context assembly).
  """

  alias OctoPi.AI.Content.Image
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Content.Thinking
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage
  alias OctoPi.AI.Usage.Cost

  @doc """
  Convert a raw session message map to the appropriate typed struct.
  Returns `nil` for unknown or unhandled roles so callers can filter.
  """
  @spec from_map(map()) :: User.t() | Assistant.t() | ToolResult.t() | nil
  def from_map(%{"role" => "user"} = m), do: user(m)
  def from_map(%{"role" => "assistant"} = m), do: assistant(m)
  def from_map(%{"role" => "toolResult"} = m), do: tool_result(m)
  def from_map(_), do: nil

  # ---- user ---------------------------------------------------------------

  defp user(m) do
    %User{
      content: content_blocks(m["content"]),
      timestamp: m["timestamp"] || :os.system_time(:millisecond)
    }
  end

  # ---- assistant ----------------------------------------------------------

  defp assistant(m) do
    %Assistant{
      api: safe_atom(m["api"]),
      provider: safe_atom(m["provider"]),
      model: m["model"] || "",
      response_id: m["responseId"],
      content: assistant_blocks(m["content"] || []),
      usage: usage(m["usage"]),
      stop_reason: stop_reason(m["stopReason"]),
      error_message: m["errorMessage"],
      timestamp: m["timestamp"] || :os.system_time(:millisecond)
    }
  end

  # ---- tool result --------------------------------------------------------

  defp tool_result(m) do
    %ToolResult{
      tool_call_id: m["tool_call_id"] || "",
      tool_name: m["tool_name"] || "",
      content: content_blocks(m["content"] || []),
      is_error?: m["is_error"] || false,
      details: nil,
      timestamp: m["timestamp"] || :os.system_time(:millisecond)
    }
  end

  # ---- content block conversion -------------------------------------------

  defp content_blocks(text) when is_binary(text), do: [%Text{text: text}]
  defp content_blocks(blocks) when is_list(blocks), do: Enum.flat_map(blocks, &user_block/1)
  defp content_blocks(_), do: []

  defp user_block(%{"type" => "text", "text" => t}), do: [%Text{text: t}]
  defp user_block(%{"type" => "image", "data" => d, "mimeType" => mt}), do: [%Image{data: d, mime_type: mt}]
  defp user_block(_), do: []

  defp assistant_blocks(blocks), do: Enum.flat_map(blocks, &assistant_block/1)

  defp assistant_block(%{"type" => "text", "text" => t}), do: [%Text{text: t}]

  defp assistant_block(%{"type" => "thinking", "thinking" => t} = b),
    do: [%Thinking{thinking: t, signature: b["thinkingSignature"], redacted?: b["redacted"] || false}]

  defp assistant_block(%{"type" => "tool_use", "id" => id, "name" => name, "input" => args}),
    do: [%ToolCall{id: id, name: name, arguments: args}]

  defp assistant_block(_), do: []

  # ---- usage / cost -------------------------------------------------------

  defp usage(nil), do: %Usage{}

  defp usage(u) do
    %Usage{
      input: u["input"] || 0,
      output: u["output"] || 0,
      cache_read: u["cacheRead"] || 0,
      cache_write: u["cacheWrite"] || 0,
      total_tokens: u["totalTokens"] || 0,
      cost: cost(u["cost"])
    }
  end

  defp cost(nil), do: %Cost{}

  defp cost(c) do
    %Cost{
      input: c["input"] || 0.0,
      output: c["output"] || 0.0,
      cache_read: c["cacheRead"] || 0.0,
      cache_write: c["cacheWrite"] || 0.0,
      total: c["total"] || 0.0
    }
  end

  # ---- helpers ------------------------------------------------------------

  defp stop_reason(nil), do: nil
  defp stop_reason(s), do: String.to_existing_atom(s)

  defp safe_atom(nil), do: nil
  defp safe_atom(s) when is_binary(s), do: String.to_atom(s)
  defp safe_atom(a) when is_atom(a), do: a
end
