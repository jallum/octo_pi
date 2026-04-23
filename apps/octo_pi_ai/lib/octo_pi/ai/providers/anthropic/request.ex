defmodule OctoPi.AI.Providers.Anthropic.Request do
  @moduledoc """
  Builds the HTTP request for Anthropic's `POST /v1/messages` endpoint.

  Pure: no network, no env-var side effects at module level. The API
  key is resolved from `opts.api_key` first, then `ANTHROPIC_API_KEY`,
  then `ANTHROPIC_OAUTH_TOKEN`. If none is set `build/3` raises.

  Phase 1 scope:
    - API-key auth only (OAuth + Copilot deferred).
    - No prompt caching placement.
    - No thinking / adaptive / output_config plumbing (deferred).
    - Message conversion covers text, thinking, tool_use, tool_result,
      image — the shape every client eventually needs.
    - Tools get `eager_input_streaming: true` and the JSON-schema
      `input_schema`.

  See `docs/port-map/anthropic.md` §1.
  """

  alias OctoPi.AI.{
    Content,
    Context,
    Message,
    Model,
    StreamOptions,
    Tool,
    ToolCall
  }

  @anthropic_version "2023-06-01"

  @type built :: %{
          url: binary(),
          method: :post,
          headers: [{binary(), binary()}],
          body: map()
        }

  @doc """
  Build a ready-to-send request map for the given model, context, and
  stream options.
  """
  @spec build(Model.t(), Context.t(), StreamOptions.t() | nil) :: built()
  def build(%Model{} = model, %Context{} = context, opts \\ nil) do
    opts = opts || %StreamOptions{}

    %{
      url: url(model),
      method: :post,
      headers: headers(opts),
      body: body(model, context, opts)
    }
  end

  # --- URL / headers ---

  @spec url(Model.t()) :: binary()
  defp url(%Model{base_url: base}), do: trim_trailing_slash(base) <> "/messages"

  defp trim_trailing_slash(url) do
    if String.ends_with?(url, "/"), do: String.slice(url, 0..-2//1), else: url
  end

  @spec headers(StreamOptions.t()) :: [{binary(), binary()}]
  defp headers(%StreamOptions{} = opts) do
    base = [
      {"x-api-key", resolve_api_key(opts)},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ]

    case opts.headers do
      nil -> base
      extra -> base ++ Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)
    end
  end

  @spec resolve_api_key(StreamOptions.t()) :: binary()
  defp resolve_api_key(%StreamOptions{api_key: key}) when is_binary(key) and key != "", do: key

  defp resolve_api_key(_opts) do
    case System.get_env("ANTHROPIC_API_KEY") ||
           System.get_env("ANTHROPIC_OAUTH_TOKEN") do
      key when is_binary(key) and key != "" ->
        key

      _ ->
        raise RuntimeError,
              "Anthropic API key not set. Pass :api_key in StreamOptions " <>
                "or export ANTHROPIC_API_KEY."
    end
  end

  # --- Body ---

  @spec body(Model.t(), Context.t(), StreamOptions.t()) :: map()
  defp body(model, context, opts) do
    max_tokens = opts.max_tokens || div(model.max_tokens, 3)

    %{
      "model" => model.id,
      "max_tokens" => max_tokens,
      "stream" => true,
      "messages" => convert_messages(context.messages)
    }
    |> maybe_put("system", system_field(context.system_prompt))
    |> maybe_put("tools", convert_tools(context.tools))
    |> maybe_put("temperature", opts.temperature)
    |> maybe_put("metadata", opts.metadata)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp system_field(nil), do: nil
  defp system_field(""), do: nil
  defp system_field(prompt), do: [%{"type" => "text", "text" => prompt}]

  # --- Tools ---

  @spec convert_tools([Tool.t()]) :: [map()]
  defp convert_tools([]), do: []

  defp convert_tools(tools) do
    Enum.map(tools, fn %Tool{} = tool ->
      %{
        "name" => tool.name,
        "description" => tool.description,
        "input_schema" => normalize_schema(tool.parameters),
        "eager_input_streaming" => true
      }
    end)
  end

  @spec normalize_schema(map()) :: map()
  defp normalize_schema(schema) do
    %{
      "type" => "object",
      "properties" => Map.get(schema, "properties", %{}),
      "required" => Map.get(schema, "required", [])
    }
  end

  # --- Messages ---

  @spec convert_messages([Message.t()]) :: [map()]
  defp convert_messages(messages) do
    {acc, pending} =
      Enum.reduce(messages, {[], []}, fn msg, {acc, pending} ->
        case msg do
          %Message.ToolResult{} = tr ->
            {acc, pending ++ [tool_result_block(tr)]}

          other ->
            acc = flush_pending(acc, pending)
            {acc ++ [convert_non_tool_result(other)], []}
        end
      end)

    flush_pending(acc, pending)
  end

  @spec flush_pending([map()], [map()]) :: [map()]
  defp flush_pending(acc, []), do: acc
  defp flush_pending(acc, pending), do: acc ++ [%{"role" => "user", "content" => pending}]

  @spec convert_non_tool_result(Message.t()) :: map()
  defp convert_non_tool_result(%Message.User{content: content}) do
    %{"role" => "user", "content" => convert_user_content(content)}
  end

  defp convert_non_tool_result(%Message.Assistant{content: content}) do
    %{"role" => "assistant", "content" => Enum.map(content, &assistant_block/1)}
  end

  @spec convert_user_content(binary() | [Content.user_block()]) :: [map()]
  defp convert_user_content(text) when is_binary(text),
    do: [%{"type" => "text", "text" => text}]

  defp convert_user_content(blocks) when is_list(blocks),
    do: Enum.map(blocks, &user_block/1)

  @spec user_block(Content.user_block()) :: map()
  defp user_block(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp user_block(%Content.Image{data: data, mime_type: mime}) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
    }
  end

  @spec assistant_block(Content.assistant_block()) :: map()
  defp assistant_block(%Content.Text{text: text}), do: %{"type" => "text", "text" => text}

  defp assistant_block(%Content.Thinking{redacted?: true} = block) do
    %{"type" => "redacted_thinking", "data" => block.signature || ""}
  end

  defp assistant_block(%Content.Thinking{} = block) do
    %{
      "type" => "thinking",
      "thinking" => block.thinking,
      "signature" => block.signature || ""
    }
  end

  defp assistant_block(%ToolCall{} = call) do
    %{
      "type" => "tool_use",
      "id" => sanitize_tool_call_id(call.id),
      "name" => call.name,
      "input" => call.arguments
    }
  end

  @spec tool_result_block(Message.ToolResult.t()) :: map()
  defp tool_result_block(%Message.ToolResult{} = tr) do
    %{
      "type" => "tool_result",
      "tool_use_id" => sanitize_tool_call_id(tr.tool_call_id),
      "content" => Enum.map(tr.content, &user_block/1),
      "is_error" => tr.is_error?
    }
  end

  # Anthropic rejects tool-call IDs that don't match ^[a-zA-Z0-9_-]{1,64}$.
  # Cross-provider history can carry IDs with other chars (OpenAI uses `|`
  # and lengths > 64) so sanitize defensively. Matches pi-mono
  # `anthropic.ts` L913-915.
  @spec sanitize_tool_call_id(binary()) :: binary()
  defp sanitize_tool_call_id(id) when is_binary(id) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 64)
  end
end
