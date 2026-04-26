defmodule OctoPi.Coder.Compaction.Tokens do
  @moduledoc """
  Token-budget calculation primitives ported from
  `tmp/pi-mono/.../compaction/compaction.ts`:

  - `calculate_context_tokens/1` (upstream lines 135-137)
  - `estimate_tokens/1`          (upstream lines 232-290)
  - `estimate_context_tokens/1`  (upstream lines 186-214)
  - `should_compact?/3`          (upstream lines 219-222)

  All four are pure. The ⌈chars/4⌉ heuristic is conservative: it
  intentionally overestimates, matching upstream so cut-point decisions
  stay byte-compatible.
  """

  alias OctoPi.AI.Content.{Image, Text, Thinking}
  alias OctoPi.AI.Message.{Assistant, ToolResult, User}
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Compaction.Settings

  @type estimate :: %{
          tokens: non_neg_integer(),
          usage_tokens: non_neg_integer(),
          trailing_tokens: non_neg_integer(),
          last_usage_index: non_neg_integer() | nil
        }

  # ---- calculate_context_tokens -------------------------------------------

  @doc """
  Total context tokens implied by a `Usage`. Prefers the native
  `total_tokens` if non-zero, else reconstructs from components.
  Mirrors `usage.totalTokens || usage.input + ... + usage.cacheWrite`.
  """
  @spec calculate_context_tokens(Usage.t()) :: non_neg_integer()
  def calculate_context_tokens(%Usage{total_tokens: t}) when is_integer(t) and t > 0, do: t

  def calculate_context_tokens(%Usage{input: i, output: o, cache_read: cr, cache_write: cw}),
    do: i + o + cr + cw

  # ---- estimate_tokens (per-message ⌈chars/4⌉) ----------------------------

  @doc """
  Conservative chars/4 estimator. Mirrors upstream's `estimateTokens`
  per-role logic. Future tickets add heads for `bash_execution`,
  `branch_summary`, and `compaction_summary` message kinds as those
  structs land (tracked under opi-ixp.43).
  """
  @spec estimate_tokens(struct() | map()) :: non_neg_integer()
  def estimate_tokens(%User{content: content}), do: ceil_div4(user_chars(content))

  def estimate_tokens(%Assistant{content: blocks}),
    do: ceil_div4(Enum.reduce(blocks, 0, &(&2 + assistant_block_chars(&1))))

  def estimate_tokens(%ToolResult{content: content}),
    do: ceil_div4(tool_result_chars(content))

  # Raw decoded-JSON message maps (as held by `Session.Entry.Message`).
  # Mirrors the typed heads above but reads from string-keyed maps so
  # callers don't need a wire→struct converter just to estimate.
  def estimate_tokens(%{"role" => "user", "content" => content}),
    do: ceil_div4(map_user_chars(content))

  def estimate_tokens(%{"role" => "assistant", "content" => blocks}) when is_list(blocks),
    do: ceil_div4(Enum.reduce(blocks, 0, &(&2 + map_assistant_block_chars(&1))))

  def estimate_tokens(%{"role" => "toolResult", "content" => content}),
    do: ceil_div4(map_tool_result_chars(content))

  def estimate_tokens(_other), do: 0

  # All char counts use `byte_size/1` (UTF-8 byte length). For ASCII the
  # value matches JS `string.length`; for multibyte text it overestimates
  # relative to JS, which keeps us inside the heuristic's conservative
  # ceiling and never under-budgets a compaction decision.

  defp user_chars(content) when is_binary(content), do: byte_size(content)

  defp user_chars(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %Text{text: t}, acc when is_binary(t) -> acc + byte_size(t)
      _, acc -> acc
    end)
  end

  defp user_chars(_), do: 0

  defp assistant_block_chars(%Text{text: t}) when is_binary(t), do: byte_size(t)
  defp assistant_block_chars(%Thinking{thinking: t}) when is_binary(t), do: byte_size(t)

  defp assistant_block_chars(%ToolCall{name: name, arguments: args}) do
    byte_size(name) + byte_size(Jason.encode!(args || %{}))
  end

  defp assistant_block_chars(_), do: 0

  defp tool_result_chars(content) when is_binary(content), do: byte_size(content)

  defp tool_result_chars(content) when is_list(content) do
    Enum.reduce(content, 0, fn
      %Text{text: t}, acc when is_binary(t) -> acc + byte_size(t)
      # Upstream estimates each image at 4800 chars (≈1200 tokens).
      %Image{}, acc -> acc + 4800
      _, acc -> acc
    end)
  end

  defp tool_result_chars(_), do: 0

  defp ceil_div4(0), do: 0
  defp ceil_div4(n) when is_integer(n) and n > 0, do: div(n + 3, 4)

  # ---- raw-map char counters --------------------------------------------

  defp map_user_chars(s) when is_binary(s), do: byte_size(s)

  defp map_user_chars(blocks) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn
      %{"type" => "text", "text" => t}, acc when is_binary(t) -> acc + byte_size(t)
      _, acc -> acc
    end)
  end

  defp map_user_chars(_), do: 0

  defp map_assistant_block_chars(%{"type" => "text", "text" => t}) when is_binary(t),
    do: byte_size(t)

  defp map_assistant_block_chars(%{"type" => "thinking", "thinking" => t}) when is_binary(t),
    do: byte_size(t)

  defp map_assistant_block_chars(%{"type" => "toolCall", "name" => name, "arguments" => args}) do
    byte_size(name) + byte_size(Jason.encode!(args || %{}))
  end

  defp map_assistant_block_chars(_), do: 0

  defp map_tool_result_chars(s) when is_binary(s), do: byte_size(s)

  defp map_tool_result_chars(blocks) when is_list(blocks) do
    Enum.reduce(blocks, 0, fn
      %{"type" => "text", "text" => t}, acc when is_binary(t) -> acc + byte_size(t)
      %{"type" => "image"}, acc -> acc + 4800
      _, acc -> acc
    end)
  end

  defp map_tool_result_chars(_), do: 0

  # ---- estimate_context_tokens -------------------------------------------

  @doc """
  Estimate total context tokens for an oldest-first list of messages,
  using the most recent assistant message's reported `usage` as a
  baseline and ⌈chars/4⌉-estimating only the trailing tail.

  Returns a map with the same shape as upstream `ContextUsageEstimate`
  (snake_case keys).
  """
  @spec estimate_context_tokens([struct()]) :: estimate()
  def estimate_context_tokens(messages) when is_list(messages) do
    case last_assistant_usage(messages) do
      nil ->
        estimated = Enum.reduce(messages, 0, &(&2 + estimate_tokens(&1)))

        %{
          tokens: estimated,
          usage_tokens: 0,
          trailing_tokens: estimated,
          last_usage_index: nil
        }

      {usage, index} ->
        usage_tokens = calculate_context_tokens(usage)

        trailing_tokens =
          messages
          |> Enum.drop(index + 1)
          |> Enum.reduce(0, &(&2 + estimate_tokens(&1)))

        %{
          tokens: usage_tokens + trailing_tokens,
          usage_tokens: usage_tokens,
          trailing_tokens: trailing_tokens,
          last_usage_index: index
        }
    end
  end

  defp last_assistant_usage(messages) do
    messages
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find_value(fn {msg, idx} ->
      case assistant_usage(msg) do
        nil -> nil
        usage -> {usage, idx}
      end
    end)
  end

  # Aborted/error assistant messages don't carry valid usage data.
  defp assistant_usage(%Assistant{stop_reason: r}) when r in [:aborted, :error], do: nil
  defp assistant_usage(%Assistant{usage: %Usage{} = u}), do: u

  # Raw decoded-JSON assistant maps. `stopReason` is wire-format
  # camelCase; `usage` is a string-keyed sub-map carrying integer
  # token counts. Mirrors the typed-struct heads above so a
  # `build_session_context` output (raw maps) flows through
  # estimate_context_tokens unchanged.
  defp assistant_usage(%{"role" => "assistant", "stopReason" => r})
       when r in ["aborted", "error"],
       do: nil

  defp assistant_usage(%{"role" => "assistant", "usage" => %{} = u}), do: usage_from_map(u)
  defp assistant_usage(_), do: nil

  defp usage_from_map(u) do
    %Usage{
      input: get_int(u, "input"),
      output: get_int(u, "output"),
      cache_read: get_int(u, "cacheRead"),
      cache_write: get_int(u, "cacheWrite"),
      total_tokens: get_int(u, "totalTokens")
    }
  end

  defp get_int(map, key) do
    case Map.get(map, key) do
      n when is_integer(n) -> n
      _ -> 0
    end
  end

  # ---- should_compact? ----------------------------------------------------

  @doc """
  `should_compact?(context_tokens, context_window, settings)` mirrors
  upstream `shouldCompact` exactly: false when settings disable
  compaction, otherwise `context_tokens > context_window - reserve`.
  """
  @spec should_compact?(non_neg_integer(), non_neg_integer(), Settings.t()) :: boolean()
  def should_compact?(_, _, %Settings{enabled: false}), do: false

  def should_compact?(context_tokens, context_window, %Settings{reserve_tokens: reserve}),
    do: context_tokens > context_window - reserve
end
