defmodule OctoPi.AI.Providers.Anthropic.Request do
  @moduledoc """
  Builds the HTTP request for Anthropic's `POST /v1/messages` endpoint.

  Pure: no network, no env-var side effects at module level. Credentials
  are resolved once by `Auth.resolve/1` and drive the rest of the
  request shape.

  - API-key credentials → `x-api-key` header; user's system prompt
    stands alone; tool names pass through untouched.
  - OAuth credentials (`sk-ant-oat...`) → `Authorization: Bearer`,
    Claude-Code beta headers, identity system prompt prepended, and
    tool names rewritten to Claude Code canonical casing via
    `ToolNames.to_claude_code/1`.

  Deferred: adaptive / budget thinking shapes, the interactive OAuth
  login-then-refresh flow (env / keychain OAuth tokens are supported already).

  See `docs/port-map/anthropic.md` §1.
  """

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Content
  alias OctoPi.AI.Context
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.Anthropic.Auth
  alias OctoPi.AI.Providers.Anthropic.Auth.Credentials
  alias OctoPi.AI.Providers.Anthropic.ToolNames
  alias OctoPi.AI.SanitizeUnicode
  alias OctoPi.AI.Tool
  alias OctoPi.AI.ToolCall

  @anthropic_version "2023-06-01"
  @claude_code_version "2.1.75"
  @oauth_identity_prompt "You are Claude Code, Anthropic's official CLI for Claude."
  @oauth_betas "claude-code-20250219,oauth-2025-04-20"

  @type built :: %{
          url: binary(),
          method: :post,
          headers: [{binary(), binary()}],
          body: map(),
          auth: Credentials.t()
        }

  @doc """
  Build a ready-to-send request map plus the resolved credentials
  (callers like the Decoder need to know whether OAuth is in play to
  reverse-normalize tool names on the response).
  """
  @spec build(Model.t(), Context.t(), CallOptions.t() | nil, Credentials.t() | nil) :: built()
  def build(%Model{} = model, %Context{} = context, opts \\ nil, auth \\ nil) do
    opts = opts || %CallOptions{}
    auth = auth || Auth.resolve(opts)

    %{
      url: url(model),
      method: :post,
      headers: headers(auth, opts),
      body: body(model, context, opts, auth),
      auth: auth
    }
  end

  # --- URL / headers ---

  @spec url(Model.t()) :: binary()
  defp url(%Model{base_url: base}), do: String.trim_trailing(base, "/") <> "/messages"

  @spec headers(Credentials.t(), CallOptions.t()) :: [{binary(), binary()}]
  defp headers(%Credentials{type: :api_key, token: token}, opts) do
    [
      {"x-api-key", token},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"},
      {"accept", "application/json"}
    ] ++ extra_headers(opts)
  end

  defp headers(%Credentials{type: :oauth, token: token}, opts) do
    [
      {"authorization", "Bearer " <> token},
      {"anthropic-version", @anthropic_version},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "claude-cli/" <> @claude_code_version},
      {"x-app", "cli"},
      {"anthropic-beta", @oauth_betas}
    ] ++ extra_headers(opts)
  end

  @spec extra_headers(CallOptions.t()) :: [{binary(), binary()}]
  defp extra_headers(%CallOptions{headers: nil}), do: []

  defp extra_headers(%CallOptions{headers: extra}), do: Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)

  # --- Body ---

  @spec body(Model.t(), Context.t(), CallOptions.t(), Credentials.t()) :: map()
  defp body(model, context, opts, auth) do
    max_tokens = opts.max_tokens || div(model.max_tokens, 3)
    oauth? = auth.type == :oauth
    cache_retention = resolve_cache_retention(opts)

    %{
      "model" => model.id,
      "max_tokens" => max_tokens,
      "stream" => true,
      "messages" => convert_messages(context.messages, oauth?)
    }
    |> maybe_put("system", system_field(context.system_prompt, oauth?))
    |> maybe_put("tools", convert_tools(context.tools, oauth?))
    |> maybe_put("temperature", opts.temperature)
    |> maybe_put("metadata", opts.metadata)
    |> apply_cache_control(model, cache_retention)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, []), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # --- Caching ---

  defp resolve_cache_retention(%CallOptions{metadata: %{"cache_retention" => r}}) when r in ["none", "short", "long"],
    do: r

  defp resolve_cache_retention(_opts), do: "short"

  defp apply_cache_control(body, _model, "none"), do: body

  defp apply_cache_control(body, model, cache_retention) do
    ttl =
      if cache_retention == "long" and String.contains?(model.base_url, "api.anthropic.com"),
        do: "1h"

    cc = if ttl, do: %{"type" => "ephemeral", "ttl" => ttl}, else: %{"type" => "ephemeral"}

    body
    |> add_cache_control_to_system(cc)
    |> add_cache_control_to_last_tool(cc)
    |> add_cache_control_to_last_conversation_msg(cc)
  end

  defp add_cache_control_to_system(%{"system" => [_ | _] = system} = body, cc) do
    Map.put(body, "system", List.update_at(system, -1, &Map.put(&1, "cache_control", cc)))
  end

  defp add_cache_control_to_system(body, _cc), do: body

  defp add_cache_control_to_last_tool(%{"tools" => [_ | _] = tools} = body, cc) do
    Map.put(body, "tools", List.update_at(tools, -1, &Map.put(&1, "cache_control", cc)))
  end

  defp add_cache_control_to_last_tool(body, _cc), do: body

  defp add_cache_control_to_last_conversation_msg(%{"messages" => messages} = body, cc) do
    idx =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {msg, i} ->
        if msg["role"] in ["user", "assistant"], do: i
      end)

    case idx do
      nil -> body
      i -> Map.put(body, "messages", List.update_at(messages, i, &add_cache_control_to_last_text_block(&1, cc)))
    end
  end

  defp add_cache_control_to_last_text_block(%{"content" => content} = msg, cc) when is_list(content) do
    idx =
      content
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {block, i} ->
        if block["type"] == "text", do: i
      end)

    case idx do
      nil -> msg
      i -> Map.put(msg, "content", List.update_at(content, i, &Map.put(&1, "cache_control", cc)))
    end
  end

  defp add_cache_control_to_last_text_block(msg, _cc), do: msg

  # --- System prompt ---

  @spec system_field(String.t() | nil, boolean()) :: [map()] | nil
  defp system_field(prompt, oauth?)

  defp system_field(nil, false), do: nil
  defp system_field("", false), do: nil
  defp system_field(prompt, false), do: [%{"type" => "text", "text" => SanitizeUnicode.sanitize(prompt)}]

  defp system_field(nil, true), do: [%{"type" => "text", "text" => @oauth_identity_prompt}]
  defp system_field("", true), do: [%{"type" => "text", "text" => @oauth_identity_prompt}]

  defp system_field(prompt, true) do
    [
      %{"type" => "text", "text" => @oauth_identity_prompt},
      %{"type" => "text", "text" => SanitizeUnicode.sanitize(prompt)}
    ]
  end

  # --- Tools ---

  @spec convert_tools([Tool.t()], boolean()) :: [map()]
  defp convert_tools([], _oauth?), do: []

  defp convert_tools(tools, oauth?) do
    Enum.map(tools, fn %Tool{} = tool ->
      %{
        "name" => rename_for_send(tool.name, oauth?),
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

  @spec convert_messages([Message.t()], boolean()) :: [map()]
  defp convert_messages(messages, oauth?) do
    # Build `acc` and `pending` newest-first via prepend; reverse once
    # at the end. Avoids the O(n²) `acc ++ [item]` pattern from the
    # original port.
    {acc_rev, pending_rev} =
      Enum.reduce(messages, {[], []}, fn msg, {acc_rev, pending_rev} ->
        case msg do
          %Message.ToolResult{} = tr ->
            {acc_rev, [tool_result_block(tr) | pending_rev]}

          other ->
            acc_rev = flush_pending(acc_rev, pending_rev)
            {[convert_non_tool_result(other, oauth?) | acc_rev], []}
        end
      end)

    acc_rev |> flush_pending(pending_rev) |> Enum.reverse()
  end

  # `acc_rev` is newest-first; `pending_rev` is also newest-first.
  # Reverse the pending block so its inner content is oldest-first
  # again, then cons the wrapped user message onto `acc_rev`.
  @spec flush_pending([map()], [map()]) :: [map()]
  defp flush_pending(acc_rev, []), do: acc_rev

  defp flush_pending(acc_rev, pending_rev), do: [%{"role" => "user", "content" => Enum.reverse(pending_rev)} | acc_rev]

  @spec convert_non_tool_result(Message.t(), boolean()) :: map()
  defp convert_non_tool_result(%Message.User{content: content}, _oauth?) do
    %{"role" => "user", "content" => convert_user_content(content)}
  end

  defp convert_non_tool_result(%Message.Assistant{content: content}, oauth?) do
    %{"role" => "assistant", "content" => Enum.map(content, &assistant_block(&1, oauth?))}
  end

  @spec convert_user_content(binary() | [Content.user_block()]) :: [map()]
  defp convert_user_content(text) when is_binary(text),
    do: [%{"type" => "text", "text" => SanitizeUnicode.sanitize(text)}]

  defp convert_user_content(blocks) when is_list(blocks), do: Enum.map(blocks, &user_block/1)

  @spec user_block(Content.user_block()) :: map()
  defp user_block(%Content.Text{text: text}), do: %{"type" => "text", "text" => SanitizeUnicode.sanitize(text)}

  defp user_block(%Content.Image{data: data, mime_type: mime}) do
    %{
      "type" => "image",
      "source" => %{"type" => "base64", "media_type" => mime, "data" => data}
    }
  end

  @spec assistant_block(Content.assistant_block(), boolean()) :: map()
  defp assistant_block(%Content.Text{text: text}, _oauth?),
    do: %{"type" => "text", "text" => SanitizeUnicode.sanitize(text)}

  defp assistant_block(%Content.Thinking{redacted?: true} = block, _oauth?) do
    %{"type" => "redacted_thinking", "data" => block.signature || ""}
  end

  defp assistant_block(%Content.Thinking{} = block, _oauth?) do
    %{
      "type" => "thinking",
      "thinking" => SanitizeUnicode.sanitize(block.thinking),
      "signature" => block.signature || ""
    }
  end

  defp assistant_block(%ToolCall{} = call, oauth?) do
    %{
      "type" => "tool_use",
      "id" => sanitize_tool_call_id(call.id),
      "name" => rename_for_send(call.name, oauth?),
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

  @spec rename_for_send(String.t(), boolean()) :: String.t()
  defp rename_for_send(name, false), do: name
  defp rename_for_send(name, true), do: ToolNames.to_claude_code(name)
end
