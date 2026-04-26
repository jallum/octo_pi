defmodule OctoPi.Coder.Compaction.Serialize do
  @moduledoc """
  Render an `AgentMessage` list as plain text for the summarization
  prompt. Pure-function port of `tmp/pi-mono/.../compaction/utils.ts`:

  - `truncate_for_summary/2` (upstream lines 95-99)
  - `conversation/1`         (upstream `serializeConversation`,
    lines 109-162)

  Output uses the upstream tag prefixes verbatim — `[User]:` /
  `[Assistant thinking]:` / `[Assistant]:` / `[Assistant tool calls]:`
  / `[Tool result]:` — so summaries the LLM produces are stable across
  the port.

  Truncation is grapheme-aware (`String.length` / `String.slice`),
  which is strictly safer than upstream's UTF-16 code-unit semantics:
  it never splits an emoji or combining sequence and the
  `[... N more characters truncated]` marker reports the count a human
  would actually call "characters." For ASCII tool output the bytes
  are identical to upstream.
  """

  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.{Assistant, ToolResult, User}
  alias OctoPi.AI.ToolCall

  @tool_result_max_chars 2_000

  # ---- truncate_for_summary ----------------------------------------------

  @doc """
  If `text` exceeds `max_chars` graphemes, keep the first `max_chars`
  graphemes and append `\\n\\n[... N more characters truncated]` where
  N is the count of dropped graphemes. Otherwise pass through.
  """
  @spec truncate_for_summary(String.t(), pos_integer()) :: String.t()
  def truncate_for_summary(text, max_chars)
      when is_binary(text) and is_integer(max_chars) and max_chars > 0 do
    len = String.length(text)

    case len > max_chars do
      false -> text
      true -> String.slice(text, 0, max_chars) <> "\n\n[... #{len - max_chars} more characters truncated]"
    end
  end

  # ---- conversation ------------------------------------------------------

  @doc """
  Serialize an oldest-first list of agent messages to a single string,
  joined by blank lines. Unknown message kinds (Custom, future
  variants) contribute nothing — matching upstream's switch which
  silently drops anything outside user/assistant/toolResult.
  """
  @spec conversation([struct()]) :: String.t()
  def conversation(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&format/1)
    |> Enum.join("\n\n")
  end

  # User: plain string content, or text-blocks-only filtered+concatenated.
  defp format(%User{content: content}) do
    text = user_text(content)

    case text do
      "" -> []
      _ -> ["[User]: " <> text]
    end
  end

  # Assistant: emit thinking, then text, then tool calls — in that order,
  # each as its own paragraph if non-empty.
  defp format(%Assistant{content: blocks}) do
    {texts, thinkings, tool_calls} = split_assistant_blocks(blocks)

    []
    |> maybe_part("[Assistant thinking]: ", thinkings)
    |> maybe_part("[Assistant]: ", texts)
    |> maybe_tool_calls(tool_calls)
    |> Enum.reverse()
  end

  # Tool result: text-blocks only, concatenated, then truncated.
  defp format(%ToolResult{content: content}) do
    text = tool_result_text(content)

    case text do
      "" -> []
      _ -> ["[Tool result]: " <> truncate_for_summary(text, @tool_result_max_chars)]
    end
  end

  defp format(_other), do: []

  # ---- helpers -----------------------------------------------------------

  defp user_text(content) when is_binary(content), do: content

  defp user_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp user_text(_), do: ""

  defp tool_result_text(content) when is_list(content) do
    content
    |> Enum.flat_map(fn
      %Text{text: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
  end

  defp tool_result_text(content) when is_binary(content), do: content
  defp tool_result_text(_), do: ""

  defp split_assistant_blocks(blocks) do
    Enum.reduce(blocks, {[], [], []}, fn
      %Text{text: t}, {ts, ths, tcs} when is_binary(t) ->
        {[t | ts], ths, tcs}

      %OctoPi.AI.Content.Thinking{thinking: t}, {ts, ths, tcs} when is_binary(t) ->
        {ts, [t | ths], tcs}

      %ToolCall{name: name, arguments: args}, {ts, ths, tcs} ->
        {ts, ths, [render_tool_call(name, args) | tcs]}

      _, acc ->
        acc
    end)
    |> reverse_triple()
  end

  defp reverse_triple({a, b, c}), do: {Enum.reverse(a), Enum.reverse(b), Enum.reverse(c)}

  defp render_tool_call(name, args) when is_map(args) do
    args_str =
      args
      |> Enum.map(fn {k, v} -> "#{k}=#{Jason.encode!(v)}" end)
      |> Enum.join(", ")

    "#{name}(#{args_str})"
  end

  defp render_tool_call(name, _), do: "#{name}()"

  defp maybe_part(parts, _prefix, []), do: parts
  defp maybe_part(parts, prefix, items), do: [prefix <> Enum.join(items, "\n") | parts]

  defp maybe_tool_calls(parts, []), do: parts

  defp maybe_tool_calls(parts, calls),
    do: ["[Assistant tool calls]: " <> Enum.join(calls, "; ") | parts]
end
