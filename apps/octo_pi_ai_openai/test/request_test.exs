defmodule OctoPi.AI.Providers.OpenAI.RequestTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.{Content, Context, Message, Model, StreamOptions, Tool, ToolCall, Usage}
  alias OctoPi.AI.Providers.OpenAI.{Compat, Request}

  defp model(attrs \\ %{}) do
    %Model{
      id: Map.get(attrs, :id, "gpt-4o"),
      name: "GPT-4o",
      api: :openai_completions,
      provider: Map.get(attrs, :provider, :openai),
      base_url: Map.get(attrs, :base_url, "https://api.openai.com/v1"),
      context_window: 128_000,
      max_tokens: Map.get(attrs, :max_tokens, 16_384),
      reasoning: Map.get(attrs, :reasoning, false),
      input: Map.get(attrs, :input, [:text, :image]),
      compat: Map.get(attrs, :compat, nil)
    }
  end

  defp context(messages, opts \\ []) do
    %Context{
      messages: messages,
      system_prompt: Keyword.get(opts, :system_prompt),
      tools: Keyword.get(opts, :tools, [])
    }
  end

  defp assistant_msg(content, overrides \\ %{}) do
    %Message.Assistant{
      content: content,
      api: Map.get(overrides, :api, :openai_completions),
      provider: Map.get(overrides, :provider, :openai),
      model: Map.get(overrides, :model, "gpt-4o"),
      usage: %Usage{},
      stop_reason: Map.get(overrides, :stop_reason, :stop),
      timestamp: :os.system_time(:millisecond)
    }
  end

  describe "build/4 — URL" do
    test "constructs URL from model base_url" do
      req = Request.build(model(), context([]), %StreamOptions{}, Compat.detect(model()))
      assert req.url == "https://api.openai.com/v1/chat/completions"
    end

    test "trims trailing slash from base_url" do
      m = model(%{base_url: "https://api.openai.com/v1/"})
      req = Request.build(m, context([]), %StreamOptions{}, Compat.detect(m))
      assert req.url == "https://api.openai.com/v1/chat/completions"
    end
  end

  describe "build/4 — body basics" do
    test "includes model, stream, and max_completion_tokens" do
      req = Request.build(model(), context([]), %StreamOptions{max_tokens: 4096}, Compat.detect(model()))

      assert req.body["model"] == "gpt-4o"
      assert req.body["stream"] == true
      assert req.body["max_completion_tokens"] == 4096
    end

    test "uses max_tokens field when compat says so" do
      compat = %{Compat.detect(model()) | max_tokens_field: :max_tokens}
      req = Request.build(model(), context([]), %StreamOptions{max_tokens: 4096}, compat)

      assert req.body["max_tokens"] == 4096
      refute Map.has_key?(req.body, "max_completion_tokens")
    end

    test "includes stream_options when supported" do
      req = Request.build(model(), context([]), %StreamOptions{}, Compat.detect(model()))
      assert req.body["stream_options"] == %{"include_usage" => true}
    end

    test "omits stream_options when not supported" do
      compat = %{Compat.detect(model()) | supports_usage_in_streaming: false}
      req = Request.build(model(), context([]), %StreamOptions{}, compat)
      refute Map.has_key?(req.body, "stream_options")
    end

    test "includes store: false when supported" do
      req = Request.build(model(), context([]), %StreamOptions{}, Compat.detect(model()))
      assert req.body["store"] == false
    end

    test "omits store for non-standard providers" do
      m = model(%{provider: :xai})
      req = Request.build(m, context([]), %StreamOptions{}, Compat.detect(m))
      refute Map.has_key?(req.body, "store")
    end

    test "passes temperature" do
      req = Request.build(model(), context([]), %StreamOptions{temperature: 0.7}, Compat.detect(model()))
      assert req.body["temperature"] == 0.7
    end
  end

  describe "system prompt" do
    test "system role for non-reasoning models" do
      ctx = context([], system_prompt: "Be helpful")
      req = Request.build(model(), ctx, %StreamOptions{}, Compat.detect(model()))

      [sys | _] = req.body["messages"]
      assert sys["role"] == "system"
      assert sys["content"] == "Be helpful"
    end

    test "developer role for reasoning models with supports_developer_role" do
      m = model(%{reasoning: true})
      ctx = context([], system_prompt: "Be helpful")
      req = Request.build(m, ctx, %StreamOptions{}, Compat.detect(m))

      [sys | _] = req.body["messages"]
      assert sys["role"] == "developer"
    end

    test "system role even for reasoning when supports_developer_role is false" do
      m = model(%{reasoning: true, provider: :xai})
      ctx = context([], system_prompt: "Be helpful")
      req = Request.build(m, ctx, %StreamOptions{}, Compat.detect(m))

      [sys | _] = req.body["messages"]
      assert sys["role"] == "system"
    end

    test "omits system message when no prompt" do
      req = Request.build(model(), context([]), %StreamOptions{}, Compat.detect(model()))
      roles = Enum.map(req.body["messages"], & &1["role"])
      refute "system" in roles
      refute "developer" in roles
    end
  end

  describe "user messages" do
    test "string content" do
      msgs = [%Message.User{content: "hello", timestamp: 0}]
      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))

      [user] = req.body["messages"]
      assert user == %{"role" => "user", "content" => "hello"}
    end

    test "text + image content blocks" do
      msgs = [
        %Message.User{
          content: [
            %Content.Text{text: "look at this"},
            %Content.Image{data: "abc123", mime_type: "image/png"}
          ],
          timestamp: 0
        }
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))
      [user] = req.body["messages"]

      assert [
        %{"type" => "text", "text" => "look at this"},
        %{"type" => "image_url", "image_url" => %{"url" => "data:image/png;base64,abc123"}}
      ] = user["content"]
    end
  end

  describe "assistant messages" do
    test "text content as plain string" do
      msgs = [
        %Message.User{content: "hi", timestamp: 0},
        assistant_msg([%Content.Text{text: "hello"}])
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))
      [_user, asst] = req.body["messages"]

      assert asst["role"] == "assistant"
      assert asst["content"] == "hello"
    end

    test "tool calls in assistant message" do
      msgs = [
        %Message.User{content: "read it", timestamp: 0},
        assistant_msg([
          %ToolCall{id: "call_1", name: "read", arguments: %{"path" => "foo.txt"}}
        ], %{stop_reason: :tool_use}),
        %Message.ToolResult{
          tool_call_id: "call_1", tool_name: "read",
          content: [%Content.Text{text: "file contents"}],
          is_error?: false, timestamp: 1
        }
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))
      [_user, asst, _tool] = req.body["messages"]

      assert [tc] = asst["tool_calls"]
      assert tc["id"] == "call_1"
      assert tc["type"] == "function"
      assert tc["function"]["name"] == "read"
      assert tc["function"]["arguments"] == ~s({"path":"foo.txt"})
    end

    test "skips empty assistant messages" do
      msgs = [
        %Message.User{content: "hi", timestamp: 0},
        assistant_msg([]),
        %Message.User{content: "retry", timestamp: 1}
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))
      roles = Enum.map(req.body["messages"], & &1["role"])
      assert roles == ["user", "user"]
    end
  end

  describe "tool result messages" do
    test "converts to role: tool with tool_call_id" do
      msgs = [
        %Message.User{content: "read it", timestamp: 0},
        assistant_msg([%ToolCall{id: "call_1", name: "read", arguments: %{}}], %{stop_reason: :tool_use}),
        %Message.ToolResult{
          tool_call_id: "call_1",
          tool_name: "read",
          content: [%Content.Text{text: "file contents"}],
          is_error?: false,
          timestamp: 1
        }
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, Compat.detect(model()))
      [_user, _asst, tool] = req.body["messages"]

      assert tool["role"] == "tool"
      assert tool["tool_call_id"] == "call_1"
      assert tool["content"] == "file contents"
    end

    test "batches tool-result images into follow-up user message" do
      m = model(%{input: [:text, :image]})

      msgs = [
        %Message.User{content: "Read the images", timestamp: 0},
        assistant_msg([
          %ToolCall{id: "tool-1", name: "read", arguments: %{}},
          %ToolCall{id: "tool-2", name: "read", arguments: %{}}
        ], %{stop_reason: :tool_use}),
        %Message.ToolResult{
          tool_call_id: "tool-1", tool_name: "read",
          content: [
            %Content.Text{text: "Read image file"},
            %Content.Image{data: "ZmFrZQ==", mime_type: "image/png"}
          ],
          is_error?: false, timestamp: 1
        },
        %Message.ToolResult{
          tool_call_id: "tool-2", tool_name: "read",
          content: [
            %Content.Text{text: "Read image file"},
            %Content.Image{data: "ZmFrZQ==", mime_type: "image/png"}
          ],
          is_error?: false, timestamp: 2
        }
      ]

      req = Request.build(m, context(msgs), %StreamOptions{}, Compat.detect(m))
      roles = Enum.map(req.body["messages"], & &1["role"])

      assert roles == ["user", "assistant", "tool", "tool", "user"]

      image_msg = List.last(req.body["messages"])
      image_parts = Enum.filter(image_msg["content"], &(&1["type"] == "image_url"))
      assert length(image_parts) == 2
    end

    test "no image follow-up for non-vision models" do
      m = model(%{input: [:text]})

      msgs = [
        %Message.User{content: "read it", timestamp: 0},
        assistant_msg([%ToolCall{id: "tc1", name: "read", arguments: %{}}], %{stop_reason: :tool_use}),
        %Message.ToolResult{
          tool_call_id: "tc1", tool_name: "read",
          content: [
            %Content.Text{text: "content"},
            %Content.Image{data: "abc", mime_type: "image/png"}
          ],
          is_error?: false, timestamp: 1
        }
      ]

      req = Request.build(m, context(msgs), %StreamOptions{}, Compat.detect(m))
      roles = Enum.map(req.body["messages"], & &1["role"])
      refute "user" in Enum.drop(roles, 1)
    end
  end

  describe "tool conversion" do
    test "converts tools to function type" do
      tools = [
        %Tool{name: "read", description: "Read a file", parameters: %{"properties" => %{"path" => %{"type" => "string"}}, "required" => ["path"]}}
      ]

      ctx = context([], tools: tools)
      req = Request.build(model(), ctx, %StreamOptions{}, Compat.detect(model()))

      [tool] = req.body["tools"]
      assert tool["type"] == "function"
      assert tool["function"]["name"] == "read"
      assert tool["function"]["description"] == "Read a file"
      assert tool["function"]["strict"] == false
    end

    test "omits strict when supports_strict_mode is false" do
      tools = [%Tool{name: "read", description: "Read", parameters: %{}}]
      compat = %{Compat.detect(model()) | supports_strict_mode: false}
      req = Request.build(model(), context([], tools: tools), %StreamOptions{}, compat)

      [tool] = req.body["tools"]
      refute Map.has_key?(tool["function"], "strict")
    end
  end

  describe "thinking/reasoning params" do
    test "openai format: reasoning_effort" do
      compat = Compat.detect(model(%{reasoning: true}))
      req = Request.build(model(%{reasoning: true}), context([]), %StreamOptions{reasoning: :high}, compat)

      assert req.body["reasoning_effort"] == "high"
    end

    test "openrouter format: reasoning object" do
      m = model(%{reasoning: true, provider: :openrouter})
      compat = Compat.detect(m)
      req = Request.build(m, context([]), %StreamOptions{reasoning: :high}, compat)

      assert req.body["reasoning"] == %{"effort" => "high"}
    end

    test "openrouter: no reasoning sends effort none" do
      m = model(%{reasoning: true, provider: :openrouter})
      compat = Compat.detect(m)
      req = Request.build(m, context([]), %StreamOptions{}, compat)

      assert req.body["reasoning"] == %{"effort" => "none"}
    end

    test "zai format: enable_thinking" do
      m = model(%{reasoning: true, provider: :zai})
      compat = Compat.detect(m)
      req = Request.build(m, context([]), %StreamOptions{reasoning: :high}, compat)

      assert req.body["enable_thinking"] == true
    end

    test "zai: no reasoning disables thinking" do
      m = model(%{reasoning: true, provider: :zai})
      compat = Compat.detect(m)
      req = Request.build(m, context([]), %StreamOptions{}, compat)

      refute Map.get(req.body, "enable_thinking")
    end

    test "reasoning_effort_map remaps levels" do
      m = model(%{reasoning: true, provider: :groq, id: "qwen/qwen3-32b"})
      compat = Compat.detect(m)
      req = Request.build(m, context([]), %StreamOptions{reasoning: :high}, compat)

      assert req.body["reasoning_effort"] == "default"
    end

    test "no reasoning params when model.reasoning is false" do
      req = Request.build(model(), context([]), %StreamOptions{reasoning: :high}, Compat.detect(model()))

      refute Map.has_key?(req.body, "reasoning_effort")
      refute Map.has_key?(req.body, "reasoning")
      refute Map.has_key?(req.body, "enable_thinking")
    end
  end

  describe "thinking as text" do
    test "converts thinking blocks to text when requires_thinking_as_text" do
      compat = %{Compat.detect(model()) | requires_thinking_as_text: true}

      msgs = [
        %Message.User{content: "think", timestamp: 0},
        assistant_msg([
          %Content.Thinking{thinking: "deep thought"},
          %Content.Text{text: "answer"}
        ])
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, compat)
      [_user, asst] = req.body["messages"]

      assert is_list(asst["content"])
      texts = Enum.map(asst["content"], & &1["text"])
      assert "deep thought" in texts
      assert "answer" in texts
    end
  end

  describe "synthetic assistant bridging" do
    test "inserts assistant message after tool result when required" do
      compat = %{Compat.detect(model()) | requires_assistant_after_tool_result: true}

      msgs = [
        %Message.User{content: "do it", timestamp: 0},
        assistant_msg([%ToolCall{id: "tc1", name: "read", arguments: %{}}], %{stop_reason: :tool_use}),
        %Message.ToolResult{
          tool_call_id: "tc1", tool_name: "read",
          content: [%Content.Text{text: "done"}],
          is_error?: false, timestamp: 1
        },
        %Message.User{content: "next", timestamp: 2}
      ]

      req = Request.build(model(), context(msgs), %StreamOptions{}, compat)
      roles = Enum.map(req.body["messages"], & &1["role"])

      assert roles == ["user", "assistant", "tool", "assistant", "user"]
    end
  end

  describe "provider routing" do
    test "includes OpenRouter provider routing when base_url matches" do
      routing = %{order: ["anthropic"], allow_fallbacks: false}
      m = model(%{base_url: "https://openrouter.ai/api/v1", provider: :openrouter})
      compat = %{Compat.detect(m) | open_router_routing: routing}
      req = Request.build(m, context([]), %StreamOptions{}, compat)

      assert req.body["provider"] == routing
    end

    test "omits OpenRouter routing when base_url does not match" do
      routing = %{order: ["anthropic"]}
      m = model(%{base_url: "https://api.openai.com/v1"})
      compat = %{Compat.detect(m) | open_router_routing: routing}
      req = Request.build(m, context([]), %StreamOptions{}, compat)

      refute Map.has_key?(req.body, "provider")
    end

    test "includes Vercel gateway routing when base_url matches" do
      routing = %{only: ["openai"], order: ["anthropic", "openai"]}
      m = model(%{base_url: "https://ai-gateway.vercel.sh/v1"})
      compat = %{Compat.detect(m) | vercel_gateway_routing: routing}
      req = Request.build(m, context([]), %StreamOptions{}, compat)

      assert req.body["providerOptions"] == %{
        "gateway" => %{"only" => ["openai"], "order" => ["anthropic", "openai"]}
      }
    end

    test "omits Vercel routing when empty" do
      m = model()
      req = Request.build(m, context([]), %StreamOptions{}, Compat.detect(m))
      refute Map.has_key?(req.body, "providerOptions")
    end
  end

  describe "GitHub Copilot headers" do
    test "adds X-Initiator user when last message is user" do
      m = model(%{provider: :github_copilot})
      msgs = [%Message.User{content: "hello", timestamp: 0}]
      req = Request.build(m, context(msgs), %StreamOptions{}, Compat.detect(m))

      assert {"x-initiator", "user"} in req.headers
      assert {"openai-intent", "conversation-edits"} in req.headers
    end

    test "adds X-Initiator agent when last message is not user" do
      m = model(%{provider: :github_copilot})
      msgs = [
        %Message.User{content: "hi", timestamp: 0},
        assistant_msg([%Content.Text{text: "hello"}])
      ]

      req = Request.build(m, context(msgs), %StreamOptions{}, Compat.detect(m))
      assert {"x-initiator", "agent"} in req.headers
    end

    test "adds Copilot-Vision-Request when images present" do
      m = model(%{provider: :github_copilot})
      msgs = [
        %Message.User{
          content: [
            %Content.Text{text: "look"},
            %Content.Image{data: "abc", mime_type: "image/png"}
          ],
          timestamp: 0
        }
      ]

      req = Request.build(m, context(msgs), %StreamOptions{}, Compat.detect(m))
      assert {"copilot-vision-request", "true"} in req.headers
    end

    test "omits copilot headers for non-copilot providers" do
      req = Request.build(model(), context([]), %StreamOptions{}, Compat.detect(model()))

      refute Enum.any?(req.headers, fn {k, _} -> k == "x-initiator" end)
      refute Enum.any?(req.headers, fn {k, _} -> k == "openai-intent" end)
    end
  end

  describe "session affinity headers" do
    test "includes session headers when compat flag set and session_id present" do
      compat = %{Compat.detect(model()) | send_session_affinity_headers: true}
      opts = %StreamOptions{metadata: %{"session_id" => "sess-123"}}
      req = Request.build(model(), context([]), opts, compat)

      assert {"session_id", "sess-123"} in req.headers
      assert {"x-client-request-id", "sess-123"} in req.headers
      assert {"x-session-affinity", "sess-123"} in req.headers
    end

    test "omits session headers when compat flag is false" do
      req = Request.build(model(), context([]), %StreamOptions{metadata: %{"session_id" => "s"}}, Compat.detect(model()))

      refute Enum.any?(req.headers, fn {k, _} -> k == "session_id" end)
    end

    test "omits session headers when no session_id in metadata" do
      compat = %{Compat.detect(model()) | send_session_affinity_headers: true}
      req = Request.build(model(), context([]), %StreamOptions{}, compat)

      refute Enum.any?(req.headers, fn {k, _} -> k == "session_id" end)
    end
  end
end
