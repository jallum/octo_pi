defmodule OctoPi.AI.Providers.Anthropic.RequestTest do
  use ExUnit.Case, async: false

  alias OctoPi.AI.CallOptions
  alias OctoPi.AI.Content
  alias OctoPi.AI.Context
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.Providers.Anthropic.Request
  alias OctoPi.AI.Tool
  alias OctoPi.AI.ToolCall

  setup do
    System.put_env("ANTHROPIC_API_KEY", "test-key-from-env")
    on_exit(fn -> System.delete_env("ANTHROPIC_API_KEY") end)
    :ok
  end

  defp model(overrides \\ []) do
    base = %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 6000
    }

    struct!(base, overrides)
  end

  defp user_context(opts \\ []) do
    %Context{
      system_prompt: opts[:system_prompt],
      messages: [%Message.User{content: "hello", timestamp: 0}],
      tools: opts[:tools] || []
    }
  end

  describe "URL + method" do
    test "posts to {base_url}/messages" do
      r = Request.build(model(), user_context(), %CallOptions{})
      assert r.method == :post
      assert r.url == "https://api.anthropic.com/v1/messages"
    end

    test "trims a trailing slash from base_url" do
      r =
        Request.build(model(base_url: "https://proxy.example/"), user_context(), %CallOptions{})

      assert r.url == "https://proxy.example/messages"
    end
  end

  describe "headers" do
    test "includes x-api-key from env by default" do
      r = Request.build(model(), user_context(), %CallOptions{})
      assert {"x-api-key", "test-key-from-env"} in r.headers
    end

    test "opts.api_key overrides env" do
      r = Request.build(model(), user_context(), %CallOptions{api_key: "override"})
      assert {"x-api-key", "override"} in r.headers
      refute {"x-api-key", "test-key-from-env"} in r.headers
    end

    test "falls back to ANTHROPIC_OAUTH_TOKEN when ANTHROPIC_API_KEY is unset" do
      System.delete_env("ANTHROPIC_API_KEY")
      System.put_env("ANTHROPIC_OAUTH_TOKEN", "oauth-token")
      on_exit(fn -> System.delete_env("ANTHROPIC_OAUTH_TOKEN") end)

      r = Request.build(model(), user_context(), %CallOptions{})
      assert {"x-api-key", "oauth-token"} in r.headers
    end

    test "raises when no credentials are available" do
      System.delete_env("ANTHROPIC_API_KEY")

      assert_raise RuntimeError, ~r/credentials not available/, fn ->
        Request.build(model(), user_context(), %CallOptions{})
      end
    end

    test "includes anthropic-version, content-type, accept" do
      r = Request.build(model(), user_context(), %CallOptions{})
      assert {"anthropic-version", "2023-06-01"} in r.headers
      assert {"content-type", "application/json"} in r.headers
      assert {"accept", "application/json"} in r.headers
    end

    test "merges opts.headers after defaults" do
      r =
        Request.build(model(), user_context(), %CallOptions{
          headers: %{"x-custom" => "1", "x-tracing" => "abc"}
        })

      assert {"x-custom", "1"} in r.headers
      assert {"x-tracing", "abc"} in r.headers
    end
  end

  describe "body basics" do
    test "always sets model, stream, and default max_tokens = floor(model.max_tokens / 3)" do
      r = Request.build(model(max_tokens: 9999), user_context(), %CallOptions{})
      assert r.body["model"] == "claude-haiku-4-5"
      assert r.body["stream"] == true
      assert r.body["max_tokens"] == div(9999, 3)
    end

    test "opts.max_tokens overrides default" do
      r = Request.build(model(), user_context(), %CallOptions{max_tokens: 512})
      assert r.body["max_tokens"] == 512
    end

    test "omits temperature by default" do
      r = Request.build(model(), user_context(), %CallOptions{})
      refute Map.has_key?(r.body, "temperature")
    end

    test "includes temperature when set" do
      r = Request.build(model(), user_context(), %CallOptions{temperature: 0.2})
      assert r.body["temperature"] == 0.2
    end

    test "omits metadata, tools, system when unset/empty" do
      r = Request.build(model(), user_context(), %CallOptions{})
      refute Map.has_key?(r.body, "metadata")
      refute Map.has_key?(r.body, "tools")
      refute Map.has_key?(r.body, "system")
    end

    test "includes metadata when set" do
      r = Request.build(model(), user_context(), %CallOptions{metadata: %{"user_id" => "u1"}})
      assert r.body["metadata"] == %{"user_id" => "u1"}
    end
  end

  describe "system prompt" do
    test "is shaped as a list of text blocks" do
      r = Request.build(model(), user_context(system_prompt: "be terse"), %CallOptions{})
      assert [%{"type" => "text", "text" => "be terse"}] = r.body["system"]
    end

    test "empty string is treated as no system prompt" do
      r = Request.build(model(), user_context(system_prompt: ""), %CallOptions{})
      refute Map.has_key?(r.body, "system")
    end
  end

  describe "messages — user" do
    test "string content becomes a single text block" do
      r = Request.build(model(), user_context(), %CallOptions{})

      assert [%{"role" => "user", "content" => [%{"type" => "text", "text" => "hello"}]}] =
               r.body["messages"]
    end

    test "list content with text + image is preserved as blocks" do
      ctx = %Context{
        messages: [
          %Message.User{
            content: [
              %Content.Text{text: "what is this?"},
              %Content.Image{data: "base64==", mime_type: "image/png"}
            ],
            timestamp: 0
          }
        ]
      }

      r = Request.build(model(), ctx, %CallOptions{})
      [msg] = r.body["messages"]
      assert msg["role"] == "user"

      assert [
               %{"type" => "text", "text" => "what is this?"},
               %{
                 "type" => "image",
                 "source" => %{
                   "type" => "base64",
                   "media_type" => "image/png",
                   "data" => "base64=="
                 }
               }
             ] = msg["content"]
    end
  end

  describe "messages — assistant" do
    test "text + thinking + tool_use blocks convert correctly" do
      assistant = %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude-haiku-4-5",
        timestamp: 0,
        content: [
          %Content.Text{text: "Let me think."},
          %Content.Thinking{thinking: "inner", signature: "sig"},
          %ToolCall{id: "toolu_1", name: "edit", arguments: %{"path" => "x"}}
        ]
      }

      ctx = %Context{messages: [assistant]}
      r = Request.build(model(), ctx, %CallOptions{})

      assert [msg] = r.body["messages"]
      assert msg["role"] == "assistant"

      assert [
               %{"type" => "text", "text" => "Let me think."},
               %{"type" => "thinking", "thinking" => "inner", "signature" => "sig"},
               %{
                 "type" => "tool_use",
                 "id" => "toolu_1",
                 "name" => "edit",
                 "input" => %{"path" => "x"}
               }
             ] = msg["content"]
    end

    test "redacted thinking serializes as redacted_thinking with data" do
      assistant = %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude-haiku-4-5",
        timestamp: 0,
        content: [
          %Content.Thinking{
            thinking: "[Reasoning redacted]",
            signature: "opaque-blob",
            redacted?: true
          }
        ]
      }

      r = Request.build(model(), %Context{messages: [assistant]}, %CallOptions{})
      [msg] = r.body["messages"]
      assert msg["content"] == [%{"type" => "redacted_thinking", "data" => "opaque-blob"}]
    end

    test "tool-call id with illegal chars is sanitized to ^[a-zA-Z0-9_-]{1,64}$" do
      bad = String.duplicate("a", 70) <> "|foo$"

      assistant = %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude-haiku-4-5",
        timestamp: 0,
        content: [%ToolCall{id: bad, name: "x", arguments: %{}}]
      }

      r = Request.build(model(), %Context{messages: [assistant]}, %CallOptions{})
      [msg] = r.body["messages"]
      [block] = msg["content"]
      assert String.length(block["id"]) == 64
      assert Regex.match?(~r/^[a-zA-Z0-9_-]+$/, block["id"])
    end

    # Parameterized — real IDs from other providers' histories.
    for {label, input, expected} <- [
          {"OpenAI-style pipe", "call_abc|arg0", "call_abc_arg0"},
          {"Google-style dot", "tool.call.123", "tool_call_123"},
          {"pure dashes / underscores pass through", "call-abc_123", "call-abc_123"},
          {"exclamation marks get underscored", "!!!", "___"},
          {"unicode coerces to underscores", "café", "caf__"},
          {"max-length clamp", String.duplicate("x", 100), String.duplicate("x", 64)}
        ] do
      @input input
      @expected expected

      test "tool-call id sanitization — #{label}" do
        assistant = %Message.Assistant{
          api: :anthropic_messages,
          provider: :anthropic,
          model: "claude-haiku-4-5",
          timestamp: 0,
          content: [%ToolCall{id: @input, name: "x", arguments: %{}}]
        }

        r = Request.build(model(), %Context{messages: [assistant]}, %CallOptions{})
        [msg] = r.body["messages"]
        [block] = msg["content"]
        assert block["id"] == @expected
        assert Regex.match?(~r/^[a-zA-Z0-9_-]{1,64}$/, block["id"])
      end
    end
  end

  describe "messages — tool_result bundling" do
    test "consecutive tool_result messages bundle into one user message" do
      results = [
        %Message.ToolResult{
          tool_call_id: "toolu_1",
          tool_name: "edit",
          content: [%Content.Text{text: "ok"}],
          is_error?: false,
          timestamp: 0
        },
        %Message.ToolResult{
          tool_call_id: "toolu_2",
          tool_name: "edit",
          content: [%Content.Text{text: "oops"}],
          is_error?: true,
          timestamp: 0
        }
      ]

      ctx = %Context{messages: results ++ [%Message.User{content: "next", timestamp: 0}]}
      r = Request.build(model(), ctx, %CallOptions{})

      assert [bundled, next] = r.body["messages"]
      assert bundled["role"] == "user"
      assert length(bundled["content"]) == 2

      assert [first_tr, second_tr] = bundled["content"]
      assert first_tr["type"] == "tool_result"
      assert first_tr["tool_use_id"] == "toolu_1"
      assert first_tr["is_error"] == false

      assert second_tr["tool_use_id"] == "toolu_2"
      assert second_tr["is_error"] == true

      assert next["role"] == "user"
    end

    test "tool_results at the end of history are still bundled" do
      result = %Message.ToolResult{
        tool_call_id: "toolu_1",
        tool_name: "edit",
        content: [%Content.Text{text: "done"}],
        is_error?: false,
        timestamp: 0
      }

      ctx = %Context{messages: [%Message.User{content: "do x", timestamp: 0}, result]}
      r = Request.build(model(), ctx, %CallOptions{})

      assert [_user, bundled] = r.body["messages"]
      assert bundled["role"] == "user"
      assert [%{"type" => "tool_result"}] = bundled["content"]
    end
  end

  describe "tools" do
    test "each tool carries input_schema (normalized) and eager_input_streaming" do
      tool = %Tool{
        name: "edit",
        description: "Edit a file.",
        parameters: %{
          "properties" => %{
            "path" => %{"type" => "string"},
            "text" => %{"type" => "string"}
          },
          "required" => ["path", "text"]
        }
      }

      r = Request.build(model(), %Context{messages: [], tools: [tool]}, %CallOptions{})

      assert [converted] = r.body["tools"]
      assert converted["name"] == "edit"
      assert converted["description"] == "Edit a file."
      assert converted["eager_input_streaming"] == true

      assert converted["input_schema"] == %{
               "type" => "object",
               "properties" => %{
                 "path" => %{"type" => "string"},
                 "text" => %{"type" => "string"}
               },
               "required" => ["path", "text"]
             }
    end

    test "missing properties / required default to empties" do
      tool = %Tool{name: "noop", description: "", parameters: %{}}

      r = Request.build(model(), %Context{messages: [], tools: [tool]}, %CallOptions{})
      [converted] = r.body["tools"]

      assert converted["input_schema"] == %{
               "type" => "object",
               "properties" => %{},
               "required" => []
             }
    end
  end

  describe "OAuth path" do
    @oauth_token "sk-ant-oat01-foobar"

    test "uses Authorization: Bearer, drops x-api-key, adds claude-cli headers" do
      r = Request.build(model(), user_context(), %CallOptions{api_key: @oauth_token})

      assert {"authorization", "Bearer " <> @oauth_token} in r.headers
      refute Enum.any?(r.headers, fn {k, _} -> k == "x-api-key" end)
      assert {"user-agent", "claude-cli/2.1.75"} in r.headers
      assert {"x-app", "cli"} in r.headers

      assert {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20"} in r.headers
    end

    test "returns resolved credentials on the built request" do
      r = Request.build(model(), user_context(), %CallOptions{api_key: @oauth_token})
      assert r.auth.type == :oauth
      assert r.auth.token == @oauth_token
    end

    test "prepends the Claude Code identity prompt when no user system prompt is set" do
      r = Request.build(model(), user_context(), %CallOptions{api_key: @oauth_token})

      assert [%{"type" => "text", "text" => "You are Claude Code," <> _}] = r.body["system"]
    end

    test "prepends identity prompt BEFORE user's system prompt" do
      r =
        Request.build(
          model(),
          user_context(system_prompt: "be terse"),
          %CallOptions{api_key: @oauth_token}
        )

      assert [
               %{"type" => "text", "text" => "You are Claude Code," <> _},
               %{"type" => "text", "text" => "be terse"}
             ] = r.body["system"]
    end

    test "tool names on outbound tool defs get Claude Code casing" do
      tool = %Tool{name: "todowrite", description: "", parameters: %{}}

      r =
        Request.build(
          model(),
          %Context{messages: [], tools: [tool]},
          %CallOptions{api_key: @oauth_token}
        )

      assert [%{"name" => "TodoWrite"}] = r.body["tools"]
    end

    test "tool names on assistant history tool_use blocks also get Claude Code casing" do
      assistant = %Message.Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude-haiku-4-5",
        timestamp: 0,
        content: [%ToolCall{id: "id_1", name: "read", arguments: %{"path" => "x"}}]
      }

      r =
        Request.build(
          model(),
          %Context{messages: [assistant]},
          %CallOptions{api_key: @oauth_token}
        )

      [msg] = r.body["messages"]
      [block] = msg["content"]
      assert block["type"] == "tool_use"
      assert block["name"] == "Read"
    end

    test "tool names that don't match any CC tool pass through" do
      tool = %Tool{name: "my_custom_tool", description: "", parameters: %{}}

      r =
        Request.build(
          model(),
          %Context{messages: [], tools: [tool]},
          %CallOptions{api_key: @oauth_token}
        )

      assert [%{"name" => "my_custom_tool"}] = r.body["tools"]
    end

    test "API-key path still omits OAuth-only headers and identity prompt" do
      r = Request.build(model(), user_context(system_prompt: "hi"), %CallOptions{})

      refute Enum.any?(r.headers, fn {k, _} -> k == "authorization" end)
      refute Enum.any?(r.headers, fn {k, _} -> k == "user-agent" end)
      refute Enum.any?(r.headers, fn {k, _} -> k == "x-app" end)
      assert [%{"type" => "text", "text" => "hi"}] = r.body["system"]
    end
  end

  describe "cache control" do
    test "adds cache_control: ephemeral to system, last tool, and last message by default" do
      tool = %Tool{name: "edit", description: "", parameters: %{}}

      ctx = %Context{
        system_prompt: "be terse",
        messages: [%Message.User{content: "hello", timestamp: 0}],
        tools: [tool]
      }

      r = Request.build(model(), ctx, %CallOptions{})

      cc = %{"type" => "ephemeral"}
      assert [%{"cache_control" => ^cc}] = r.body["system"]
      assert [%{"cache_control" => ^cc}] = r.body["tools"]

      [msg] = r.body["messages"]
      assert [%{"cache_control" => ^cc}] = msg["content"]
    end

    test "adds ttl: 1h when cache_retention is long and base_url is api.anthropic.com" do
      ctx = %Context{
        system_prompt: "be terse",
        messages: [%Message.User{content: "hello", timestamp: 0}],
        tools: []
      }

      opts = %CallOptions{metadata: %{"cache_retention" => "long"}}
      r = Request.build(model(), ctx, opts)

      cc = %{"type" => "ephemeral", "ttl" => "1h"}
      assert [%{"cache_control" => ^cc}] = r.body["system"]
    end

    test "omits ttl when cache_retention is long but base_url is a proxy" do
      ctx = %Context{
        system_prompt: "be terse",
        messages: [%Message.User{content: "hello", timestamp: 0}],
        tools: []
      }

      opts = %CallOptions{metadata: %{"cache_retention" => "long"}}
      r = Request.build(model(base_url: "https://my-proxy.example.com/v1"), ctx, opts)

      cc = %{"type" => "ephemeral"}
      assert [%{"cache_control" => ^cc}] = r.body["system"]
    end

    test "omits cache_control entirely when cache_retention is none" do
      ctx = %Context{
        system_prompt: "be terse",
        messages: [%Message.User{content: "hello", timestamp: 0}],
        tools: []
      }

      opts = %CallOptions{metadata: %{"cache_retention" => "none"}}
      r = Request.build(model(), ctx, opts)

      assert [%{"type" => "text", "text" => "be terse"}] = r.body["system"]
      refute Map.has_key?(hd(r.body["system"]), "cache_control")
    end

    test "skips system cache_control when there is no system prompt" do
      r = Request.build(model(), user_context(), %CallOptions{})
      refute Map.has_key?(r.body, "system")
    end

    test "skips tool cache_control when there are no tools" do
      r = Request.build(model(), user_context(system_prompt: "hi"), %CallOptions{})
      refute Map.has_key?(r.body, "tools")
    end

    test "applies cache_control to last tool only when multiple tools are present" do
      tools = [
        %Tool{name: "read", description: "", parameters: %{}},
        %Tool{name: "edit", description: "", parameters: %{}}
      ]

      ctx = %Context{messages: [%Message.User{content: "hi", timestamp: 0}], tools: tools}
      r = Request.build(model(), ctx, %CallOptions{})

      cc = %{"type" => "ephemeral"}
      [first, last] = r.body["tools"]
      refute Map.has_key?(first, "cache_control")
      assert last["cache_control"] == cc
    end

    test "applies cache_control to last text block in multi-block user message" do
      ctx = %Context{
        messages: [
          %Message.User{
            content: [
              %Content.Text{text: "what is this?"},
              %Content.Image{data: "base64==", mime_type: "image/png"}
            ],
            timestamp: 0
          }
        ]
      }

      r = Request.build(model(), ctx, %CallOptions{})
      [msg] = r.body["messages"]
      [text_block, image_block] = msg["content"]

      assert text_block["cache_control"] == %{"type" => "ephemeral"}
      refute Map.has_key?(image_block, "cache_control")
    end

    test "cache_control on last message targets last user/assistant, not tool_result bundles" do
      ctx = %Context{
        messages: [
          %Message.User{content: "do x", timestamp: 0},
          %Message.ToolResult{
            tool_call_id: "toolu_1",
            tool_name: "edit",
            content: [%Content.Text{text: "done"}],
            is_error?: false,
            timestamp: 0
          }
        ]
      }

      r = Request.build(model(), ctx, %CallOptions{})

      # tool_result bundles into a user message — that is the last user message
      [_first, bundled] = r.body["messages"]
      assert bundled["role"] == "user"
      # tool_result blocks have no text type — no cache_control added
      [tr_block] = bundled["content"]
      assert tr_block["type"] == "tool_result"
      refute Map.has_key?(tr_block, "cache_control")
    end

    test "OAuth: cache_control goes on the last of the two system blocks" do
      @oauth_token = "sk-ant-oat01-foobar"

      ctx = %Context{
        system_prompt: "be terse",
        messages: [%Message.User{content: "hello", timestamp: 0}],
        tools: []
      }

      r = Request.build(model(), ctx, %CallOptions{api_key: @oauth_token})

      cc = %{"type" => "ephemeral"}
      [identity, user_sys] = r.body["system"]
      refute Map.has_key?(identity, "cache_control")
      assert user_sys["cache_control"] == cc
    end
  end

  describe "SanitizeUnicode — invalid UTF-8 bytes are stripped at serialization" do
    @invalid_utf8 "hello" <> <<0xFF>> <> " world"

    test "user message string with invalid bytes serializes cleanly" do
      ctx = %Context{messages: [%Message.User{content: @invalid_utf8, timestamp: 0}]}
      r = Request.build(model(), ctx, %CallOptions{})
      [msg] = r.body["messages"]
      [block] = msg["content"]
      assert block["text"] == "hello world"
      assert String.valid?(block["text"])
    end

    test "user message text block with invalid bytes serializes cleanly" do
      ctx = %Context{
        messages: [%Message.User{content: [%Content.Text{text: @invalid_utf8}], timestamp: 0}]
      }

      r = Request.build(model(), ctx, %CallOptions{})
      [msg] = r.body["messages"]
      [block] = msg["content"]
      assert block["text"] == "hello world"
      assert String.valid?(block["text"])
    end

    test "system prompt with invalid bytes serializes cleanly" do
      ctx = %Context{
        system_prompt: @invalid_utf8,
        messages: [%Message.User{content: "hi", timestamp: 0}]
      }

      r = Request.build(model(), ctx, %CallOptions{})
      [sys_block] = r.body["system"]
      assert sys_block["text"] == "hello world"
      assert String.valid?(sys_block["text"])
    end

    test "valid unicode (emoji, CJK) passes through unchanged" do
      text = "Hello 🎉 世界"

      ctx = %Context{messages: [%Message.User{content: text, timestamp: 0}]}
      r = Request.build(model(), ctx, %CallOptions{})
      [msg] = r.body["messages"]
      [block] = msg["content"]
      assert block["text"] == text
    end
  end
end
