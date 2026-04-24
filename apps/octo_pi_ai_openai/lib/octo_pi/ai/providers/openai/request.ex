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

  alias OctoPi.AI.{
    Content,
    Context,
    Message,
    Model,
    StreamOptions,
    Tool,
    ToolCall,
    TransformMessages
  }

  alias OctoPi.AI.Providers.OpenAI.Compat

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
      headers: headers(opts),
      body: body(model, context, opts, compat)
    }
  end

  # --- URL / headers ---

  defp url(%Model{base_url: base}),
    do: String.trim_trailing(base, "/") <> "/chat/completions"

  defp headers(%StreamOptions{headers: nil}),
    do: [{"content-type", "application/json"}, {"accept", "application/json"}]

  defp headers(%StreamOptions{headers: extra}) do
    base = [{"content-type", "application/json"}, {"accept", "application/json"}]
    base ++ Enum.map(extra, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  # --- Body ---

  defp body(model, context, opts, compat) do
    messages = convert_messages(model, context, compat)

    %{"model" => model.id, "stream" => true, "messages" => messages}
    |> put_max_tokens(opts, compat)
    |> put_stream_options(compat)
    |> put_store(compat)
    |> put_temperature(opts)
    |> put_tools(context, compat)
    |> put_reasoning(model, opts, compat)
    |> put_routing(model, compat)
  end

  defp put_max_tokens(body, %StreamOptions{max_tokens: nil}, _compat), do: body

  defp put_max_tokens(body, %StreamOptions{max_tokens: max}, %Compat{max_tokens_field: :max_tokens}),
    do: Map.put(body, "max_tokens", max)

  defp put_max_tokens(body, %StreamOptions{max_tokens: max}, _compat),
    do: Map.put(body, "max_completion_tokens", max)

  defp put_stream_options(body, %Compat{supports_usage_in_streaming: true}),
    do: Map.put(body, "stream_options", %{"include_usage" => true})

  defp put_stream_options(body, _compat), do: body

  defp put_store(body, %Compat{supports_store: true}),
    do: Map.put(body, "store", false)

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

      if gateway != %{},
        do: Map.put(body, "providerOptions", %{"gateway" => gateway}),
        else: body
    else
      body
    end
  end

  defp put_routing(body, _model, _compat), do: body

  # --- Tools ---

  defp convert_tools(tools, compat) do
    Enum.map(tools, fn %Tool{} = tool ->
      func =
        %{
          "name" => tool.name,
          "description" => tool.description,
          "parameters" => tool.parameters
        }
        |> maybe_put_strict(compat)

      %{"type" => "function", "function" => func}
    end)
  end

  defp maybe_put_strict(func, %Compat{supports_strict_mode: true}),
    do: Map.put(func, "strict", false)

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
    do: [%{"role" => "developer", "content" => prompt}]

  defp system_messages(prompt, _model, _compat),
    do: [%{"role" => "system", "content" => prompt}]

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
    %{"role" => "user", "content" => text}
  end

  defp convert_user(%Message.User{content: blocks}) when is_list(blocks) do
    parts = Enum.map(blocks, &user_content_part/1)
    if parts == [], do: nil, else: %{"role" => "user", "content" => parts}
  end

  defp user_content_part(%Content.Text{text: text}),
    do: %{"type" => "text", "text" => text}

  defp user_content_part(%Content.Image{data: data, mime_type: mime}),
    do: %{"type" => "image_url", "image_url" => %{"url" => "data:#{mime};base64,#{data}"}}

  # --- Assistant ---

  defp convert_assistant(%Message.Assistant{content: content}, compat) do
    text_blocks =
      content
      |> Enum.filter(&match?(%Content.Text{}, &1))
      |> Enum.filter(&(String.trim(&1.text) != ""))

    thinking_blocks =
      content
      |> Enum.filter(&match?(%Content.Thinking{}, &1))
      |> Enum.filter(&(&1.thinking != nil and String.trim(&1.thinking) != ""))

    tool_calls = Enum.filter(content, &match?(%ToolCall{}, &1))
    text = text_blocks |> Enum.map(& &1.text) |> Enum.join("")

    msg = %{"role" => "assistant"}

    msg =
      cond do
        thinking_blocks != [] and compat.requires_thinking_as_text ->
          thinking_parts =
            Enum.map(thinking_blocks, fn b -> %{"type" => "text", "text" => b.thinking} end)

          text_parts =
            Enum.map(text_blocks, fn b -> %{"type" => "text", "text" => b.text} end)

          Map.put(msg, "content", thinking_parts ++ text_parts)

        text != "" ->
          Map.put(msg, "content", text)

        true ->
          Map.put(msg, "content", nil)
      end

    msg =
      if tool_calls != [] do
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
      else
        msg
      end

    has_content =
      case msg["content"] do
        nil -> false
        "" -> false
        s when is_binary(s) -> s != ""
        l when is_list(l) -> l != []
        _ -> false
      end

    if has_content or Map.has_key?(msg, "tool_calls"), do: msg, else: nil
  end

  # --- Tool Result ---

  defp convert_tool_result(%Message.ToolResult{} = tr, model, compat) do
    text_parts =
      tr.content
      |> Enum.filter(&match?(%Content.Text{}, &1))
      |> Enum.map(& &1.text)

    text_result = Enum.join(text_parts, "\n")
    content = if text_result != "", do: text_result, else: "(see attached image)"

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
