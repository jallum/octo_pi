defmodule OctoPi.AI.Providers.OpenAI.Request do
  @moduledoc """
  Builds the HTTP request map for OpenAI's `POST /chat/completions`
  endpoint (and compatible providers). Pure: no network, no env-var
  side effects.

  The `build/4` function takes a model, context, stream options, and
  resolved compat struct and returns a map with `:url`, `:method`,
  `:headers`, and `:body` keys.

  Ported from `openai-completions.ts` L460-933.
  """

  alias OctoPi.AI.Content
  alias OctoPi.AI.Context
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.OpenAI.Compat
  alias OctoPi.AI.SanitizeUnicode
  alias OctoPi.AI.StreamOptions
  alias OctoPi.AI.Tool
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.TransformMessages

  @type built :: %{
          url: binary(),
          method: :post,
          headers: [{binary(), binary()}],
          body: map()
        }

  @spec build(Model.t(), Context.t(), StreamOptions.t(), Compat.t()) :: built()
  def build(%Model{} = model, %Context{} = context, %StreamOptions{} = opts, %Compat{} = compat) do
    %{
      url: url(model),
      method: :post,
      headers: headers(model, context, opts, compat),
      body: body(model, context, opts, compat)
    }
  end

  # --- URL / headers ---

  defp url(%Model{base_url: base}), do: String.trim_trailing(base, "/") <> "/chat/completions"

  defp headers(model, context, opts, compat) do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]

    base
    |> auth_header(opts)
    |> copilot_headers(model, context)
    |> session_affinity_headers(opts, compat)
    |> extra_headers(opts)
  end

  defp auth_header(hdrs, %StreamOptions{api_key: key}) when is_binary(key) and key != "",
    do: hdrs ++ [{"authorization", "Bearer " <> key}]

  defp auth_header(hdrs, _opts), do: hdrs

  defp copilot_headers(hdrs, %Model{provider: :github_copilot}, %Context{messages: messages}) do
    initiator = if match?(%Message.User{}, List.last(messages)), do: "user", else: "agent"
    has_images = has_vision_input?(messages)

    hdrs = hdrs ++ [{"x-initiator", initiator}, {"openai-intent", "conversation-edits"}]
    if has_images, do: hdrs ++ [{"copilot-vision-request", "true"}], else: hdrs
  end

  defp copilot_headers(hdrs, _model, _context), do: hdrs

  defp has_vision_input?([]), do: false

  defp has_vision_input?([msg | rest]) do
    has_image =
      case msg do
        %Message.User{content: blocks} when is_list(blocks) ->
          Enum.any?(blocks, &match?(%Content.Image{}, &1))

        %Message.ToolResult{content: blocks} ->
          Enum.any?(blocks, &match?(%Content.Image{}, &1))

        _ ->
          false
      end

    has_image or has_vision_input?(rest)
  end

  defp session_affinity_headers(hdrs, %StreamOptions{} = opts, %Compat{send_session_affinity_headers: true}) do
    session_id = get_in(opts.metadata || %{}, ["session_id"])

    if session_id do
      hdrs ++
        [
          {"session_id", session_id},
          {"x-client-request-id", session_id},
          {"x-session-affinity", session_id}
        ]
    else
      hdrs
    end
  end

  defp session_affinity_headers(hdrs, _opts, _compat), do: hdrs

  defp extra_headers(hdrs, %StreamOptions{headers: nil}), do: hdrs

  defp extra_headers(hdrs, %StreamOptions{headers: extra}),
    do: hdrs ++ Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)

  # --- Body ---

  defp body(model, context, opts, compat) do
    messages = convert_messages(model, context, compat)
    cache_retention = resolve_cache_retention(opts)

    %{"model" => model.id, "stream" => true, "messages" => messages}
    |> put_max_tokens(opts, compat)
    |> put_stream_options(compat)
    |> put_store(compat)
    |> put_temperature(opts)
    |> put_tools(context, compat)
    |> put_reasoning(model, opts, compat)
    |> put_routing(model, compat)
    |> put_prompt_cache(model, opts, cache_retention)
    |> apply_cache_control(model, compat, cache_retention)
  end

  defp put_max_tokens(body, %StreamOptions{max_tokens: nil}, _compat), do: body

  defp put_max_tokens(body, %StreamOptions{max_tokens: max}, %Compat{max_tokens_field: :max_tokens}),
    do: Map.put(body, "max_tokens", max)

  defp put_max_tokens(body, %StreamOptions{max_tokens: max}, _compat), do: Map.put(body, "max_completion_tokens", max)

  defp put_stream_options(body, %Compat{supports_usage_in_streaming: true}),
    do: Map.put(body, "stream_options", %{"include_usage" => true})

  defp put_stream_options(body, _compat), do: body

  defp put_store(body, %Compat{supports_store: true}), do: Map.put(body, "store", false)

  defp put_store(body, _compat), do: body

  defp put_temperature(body, %StreamOptions{temperature: nil}), do: body
  defp put_temperature(body, %StreamOptions{temperature: t}), do: Map.put(body, "temperature", t)

  defp put_tools(body, %Context{tools: []}, _compat), do: body

  defp put_tools(body, %Context{tools: tools}, compat) do
    converted = convert_tools(tools, compat)
    body = Map.put(body, "tools", converted)
    if compat.zai_tool_stream, do: Map.put(body, "tool_stream", true), else: body
  end

  defp put_reasoning(body, %Model{reasoning: false}, _opts, _compat), do: body

  defp put_reasoning(body, _model, opts, %Compat{thinking_format: :zai}) do
    Map.put(body, "enable_thinking", opts.reasoning != nil)
  end

  defp put_reasoning(body, _model, opts, %Compat{thinking_format: :openrouter} = compat) do
    if opts.reasoning do
      effort = map_reasoning_effort(opts.reasoning, compat.reasoning_effort_map)
      Map.put(body, "reasoning", %{"effort" => effort})
    else
      Map.put(body, "reasoning", %{"effort" => "none"})
    end
  end

  defp put_reasoning(body, _model, %StreamOptions{reasoning: nil}, _compat), do: body

  defp put_reasoning(body, _model, opts, %Compat{supports_reasoning_effort: true} = compat) do
    effort = map_reasoning_effort(opts.reasoning, compat.reasoning_effort_map)
    Map.put(body, "reasoning_effort", effort)
  end

  defp put_reasoning(body, _model, _opts, _compat), do: body

  defp map_reasoning_effort(level, effort_map) do
    Map.get(effort_map, level, to_string(level))
  end

  # --- Routing ---

  defp put_routing(body, %Model{base_url: base_url}, %Compat{open_router_routing: routing})
       when routing != %{} and is_map(routing) do
    if String.contains?(base_url, "openrouter.ai"),
      do: Map.put(body, "provider", routing),
      else: body
  end

  defp put_routing(body, %Model{base_url: base_url}, %Compat{vercel_gateway_routing: routing})
       when routing != %{} and is_map(routing) do
    if String.contains?(base_url, "ai-gateway.vercel.sh") do
      gateway = %{}
      gateway = if routing[:only], do: Map.put(gateway, "only", routing[:only]), else: gateway
      gateway = if routing[:order], do: Map.put(gateway, "order", routing[:order]), else: gateway

      if gateway == %{},
        do: body,
        else: Map.put(body, "providerOptions", %{"gateway" => gateway})
    else
      body
    end
  end

  defp put_routing(body, _model, _compat), do: body

  # --- Caching ---

  defp resolve_cache_retention(%StreamOptions{metadata: %{"cache_retention" => r}}) when r in ["none", "short", "long"],
    do: r

  defp resolve_cache_retention(_opts), do: "short"

  defp put_prompt_cache(body, %Model{base_url: base_url}, opts, cache_retention) do
    if String.contains?(base_url, "api.openai.com") do
      session_id = get_in(opts.metadata || %{}, ["session_id"])

      body
      |> maybe_put_cache_key(session_id, cache_retention)
      |> maybe_put_cache_retention(cache_retention)
    else
      body
    end
  end

  defp maybe_put_cache_key(body, session_id, cache_retention) when cache_retention != "none" and session_id != nil do
    Map.put(body, "prompt_cache_key", session_id)
  end

  defp maybe_put_cache_key(body, _session_id, _cache_retention), do: body

  defp maybe_put_cache_retention(body, "long"), do: Map.put(body, "prompt_cache_retention", "24h")

  defp maybe_put_cache_retention(body, _cache_retention), do: body

  defp apply_cache_control(body, _model, %Compat{cache_control_format: nil}, _retention), do: body
  defp apply_cache_control(body, _model, _compat, "none"), do: body

  defp apply_cache_control(body, model, %Compat{cache_control_format: :anthropic}, cache_retention) do
    ttl =
      if cache_retention == "long" and String.contains?(model.base_url, "api.anthropic.com"),
        do: "1h"

    cc = if ttl, do: %{"type" => "ephemeral", "ttl" => ttl}, else: %{"type" => "ephemeral"}

    messages = body["messages"]
    tools = body["tools"]

    messages = add_cache_control_to_system(messages, cc)
    tools = add_cache_control_to_last_tool(tools, cc)
    messages = add_cache_control_to_last_conversation_msg(messages, cc)

    body
    |> Map.put("messages", messages)
    |> then(fn b -> if tools, do: Map.put(b, "tools", tools), else: b end)
  end

  defp add_cache_control_to_system(messages, cc) do
    case Enum.find_index(messages, &(&1["role"] in ["system", "developer"])) do
      nil -> messages
      idx -> List.update_at(messages, idx, &add_cache_control_to_text_content(&1, cc))
    end
  end

  defp add_cache_control_to_last_tool(nil, _cc), do: nil
  defp add_cache_control_to_last_tool([], _cc), do: []

  defp add_cache_control_to_last_tool(tools, cc) do
    List.update_at(tools, -1, &Map.put(&1, "cache_control", cc))
  end

  defp add_cache_control_to_last_conversation_msg(messages, cc) do
    idx =
      messages
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {msg, i} ->
        if msg["role"] in ["user", "assistant"], do: i
      end)

    case idx do
      nil -> messages
      i -> List.update_at(messages, i, &add_cache_control_to_text_content(&1, cc))
    end
  end

  defp add_cache_control_to_text_content(%{"content" => content} = msg, cc) when is_binary(content) do
    if content == "" do
      msg
    else
      Map.put(msg, "content", [%{"type" => "text", "text" => content, "cache_control" => cc}])
    end
  end

  defp add_cache_control_to_text_content(%{"content" => content} = msg, cc) when is_list(content) do
    idx =
      content
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find_value(fn {part, i} ->
        if part["type"] == "text", do: i
      end)

    case idx do
      nil -> msg
      i -> Map.put(msg, "content", List.update_at(content, i, &Map.put(&1, "cache_control", cc)))
    end
  end

  defp add_cache_control_to_text_content(msg, _cc), do: msg

  # --- Tools ---

  defp convert_tools(tools, compat) do
    Enum.map(tools, fn %Tool{} = tool ->
      func =
        maybe_put_strict(
          %{"name" => tool.name, "description" => tool.description, "parameters" => tool.parameters},
          compat
        )

      %{"type" => "function", "function" => func}
    end)
  end

  defp maybe_put_strict(func, %Compat{supports_strict_mode: true}), do: Map.put(func, "strict", false)

  defp maybe_put_strict(func, _compat), do: func

  # --- Messages ---

  defp convert_messages(model, context, compat) do
    transformed = TransformMessages.transform(context.messages, model)

    system = system_messages(context.system_prompt, model, compat)

    {result_rev, _last_role, pending_images} =
      Enum.reduce(transformed, {[], nil, []}, fn msg, {acc, last_role, images} ->
        convert_message(msg, acc, last_role, images, model, compat)
      end)

    result_rev = flush_images(result_rev, pending_images, compat)

    system ++ Enum.reverse(result_rev)
  end

  defp system_messages(nil, _model, _compat), do: []

  defp system_messages(prompt, %Model{reasoning: true}, %Compat{supports_developer_role: true}),
    do: [%{"role" => "developer", "content" => SanitizeUnicode.sanitize(prompt)}]

  defp system_messages(prompt, _model, _compat),
    do: [%{"role" => "system", "content" => SanitizeUnicode.sanitize(prompt)}]

  # --- Per-message conversion ---

  defp convert_message(%Message.User{} = msg, acc, last_role, images, _model, compat) do
    acc = flush_images(acc, images, compat)
    acc = maybe_bridge_assistant(acc, last_role, compat)

    case convert_user(msg) do
      nil -> {acc, last_role, []}
      m -> {[m | acc], "user", []}
    end
  end

  defp convert_message(%Message.Assistant{} = msg, acc, _last_role, images, _model, compat) do
    acc = flush_images(acc, images, compat)

    case convert_assistant(msg, compat) do
      nil -> {acc, nil, []}
      m -> {[m | acc], "assistant", []}
    end
  end

  defp convert_message(%Message.ToolResult{} = msg, acc, _last_role, images, model, compat) do
    {tool_msg, img_blocks} = convert_tool_result(msg, model, compat)
    {[tool_msg | acc], "toolResult", images ++ img_blocks}
  end

  defp flush_images(acc, [], _compat), do: acc

  defp flush_images(acc, images, compat) do
    acc =
      if compat.requires_assistant_after_tool_result do
        [%{"role" => "assistant", "content" => "I have processed the tool results."} | acc]
      else
        acc
      end

    image_msg = %{
      "role" => "user",
      "content" => [%{"type" => "text", "text" => "Attached image(s) from tool result:"} | images]
    }

    [image_msg | acc]
  end

  defp maybe_bridge_assistant(acc, "toolResult", %Compat{requires_assistant_after_tool_result: true}) do
    [%{"role" => "assistant", "content" => "I have processed the tool results."} | acc]
  end

  defp maybe_bridge_assistant(acc, _last_role, _compat), do: acc

  # --- User ---

  defp convert_user(%Message.User{content: text}) when is_binary(text) do
    %{"role" => "user", "content" => SanitizeUnicode.sanitize(text)}
  end

  defp convert_user(%Message.User{content: blocks}) when is_list(blocks) do
    parts = Enum.map(blocks, &user_content_part/1)
    if parts == [], do: nil, else: %{"role" => "user", "content" => parts}
  end

  defp user_content_part(%Content.Text{text: text}), do: %{"type" => "text", "text" => SanitizeUnicode.sanitize(text)}

  defp user_content_part(%Content.Image{data: data, mime_type: mime}),
    do: %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime};base64,#{data}"}}

  # --- Assistant ---

  defp convert_assistant(%Message.Assistant{content: content}, compat) do
    text_blocks =
      Enum.filter(content, fn
        %Content.Text{text: t} -> String.trim(t) != ""
        _ -> false
      end)

    thinking_blocks =
      Enum.filter(content, fn
        %Content.Thinking{thinking: t} when t != nil -> String.trim(t) != ""
        _ -> false
      end)

    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))
    text = Enum.map_join(text_blocks, "", & &1.text)

    msg = %{"role" => "assistant"}
    msg = put_assistant_content(msg, text_blocks, thinking_blocks, text, compat)
    msg = put_assistant_tool_calls(msg, tool_calls)

    if has_content?(msg) or Map.has_key?(msg, "tool_calls"), do: msg
  end

  defp put_assistant_content(msg, text_blocks, thinking_blocks, _text, %Compat{requires_thinking_as_text: true})
       when thinking_blocks != [] do
    thinking_parts =
      Enum.map(thinking_blocks, fn b -> %{"type" => "text", "text" => SanitizeUnicode.sanitize(b.thinking)} end)

    text_parts = Enum.map(text_blocks, fn b -> %{"type" => "text", "text" => SanitizeUnicode.sanitize(b.text)} end)
    Map.put(msg, "content", thinking_parts ++ text_parts)
  end

  defp put_assistant_content(msg, _text_blocks, _thinking_blocks, text, _compat) when text != "" do
    Map.put(msg, "content", SanitizeUnicode.sanitize(text))
  end

  defp put_assistant_content(msg, _text_blocks, _thinking_blocks, _text, _compat) do
    Map.put(msg, "content", nil)
  end

  defp put_assistant_tool_calls(msg, []), do: msg

  defp put_assistant_tool_calls(msg, tool_calls) do
    wire_tcs =
      Enum.map(tool_calls, fn tc ->
        %{
          "id" => tc.id,
          "type" => "function",
          "function" => %{
            "name" => tc.name,
            "arguments" => Jason.encode!(tc.arguments)
          }
        }
      end)

    Map.put(msg, "tool_calls", wire_tcs)
  end

  defp has_content?(%{"content" => nil}), do: false
  defp has_content?(%{"content" => ""}), do: false
  defp has_content?(%{"content" => s}) when is_binary(s), do: s != ""
  defp has_content?(%{"content" => l}) when is_list(l), do: l != []
  defp has_content?(_msg), do: false

  # --- Tool Result ---

  defp convert_tool_result(%Message.ToolResult{} = tr, model, compat) do
    text_parts =
      tr.content
      |> Enum.filter(&match?(%Content.Text{}, &1))
      |> Enum.map(& &1.text)

    text_result = Enum.join(text_parts, "\n")
    content = if text_result == "", do: "(see attached image)", else: text_result

    tool_msg = %{
      "role" => "tool",
      "content" => content,
      "tool_call_id" => tr.tool_call_id
    }

    tool_msg =
      if compat.requires_tool_result_name and tr.tool_name do
        Map.put(tool_msg, "name", tr.tool_name)
      else
        tool_msg
      end

    image_blocks =
      if :image in model.input do
        tr.content
        |> Enum.filter(&match?(%Content.Image{}, &1))
        |> Enum.map(fn %Content.Image{data: data, mime_type: mime} ->
          %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime};base64,#{data}"}}
        end)
      else
        []
      end

    {tool_msg, image_blocks}
  end
end
