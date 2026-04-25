defmodule OctoPi.AI.TransformMessagesTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Content
  alias OctoPi.AI.Message
  alias OctoPi.AI.Model
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.TransformMessages
  alias OctoPi.AI.Usage

  # Matches Anthropic's tool-call ID normalization
  defp anthropic_normalize(id, _model, _source) do
    id
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "_")
    |> String.slice(0, 64)
  end

  defp copilot_claude_model do
    %Model{
      id: "claude-sonnet-4",
      name: "Claude Sonnet 4",
      api: :anthropic_messages,
      provider: :github_copilot,
      base_url: "https://api.individual.githubcopilot.com",
      reasoning: true,
      input: [:text, :image],
      context_window: 128_000,
      max_tokens: 16_000
    }
  end

  defp copilot_assistant(content, overrides \\ %{}) do
    %Message.Assistant{
      content: content,
      api: Map.get(overrides, :api, :openai_responses),
      provider: Map.get(overrides, :provider, :github_copilot),
      model: Map.get(overrides, :model, "gpt-5"),
      usage: %Usage{},
      stop_reason: Map.get(overrides, :stop_reason, :tool_use),
      timestamp: :os.system_time(:millisecond)
    }
  end

  defp user_msg(text) do
    %Message.User{content: text, timestamp: :os.system_time(:millisecond)}
  end

  defp tool_result(tool_call_id, tool_name, text, opts \\ []) do
    %Message.ToolResult{
      tool_call_id: tool_call_id,
      tool_name: tool_name,
      content: [%Content.Text{text: text}],
      is_error?: Keyword.get(opts, :is_error?, false),
      timestamp: :os.system_time(:millisecond)
    }
  end

  describe "thinking blocks — cross-model" do
    test "converts thinking blocks to text when source model differs" do
      model = copilot_claude_model()

      messages = [
        user_msg("hello"),
        %Message.Assistant{
          content: [
            %Content.Thinking{
              thinking: "Let me think about this...",
              signature: "reasoning_content"
            },
            %Content.Text{text: "Hi there!"}
          ],
          api: :openai_completions,
          provider: :github_copilot,
          model: "gpt-4o",
          usage: %Usage{},
          stop_reason: :stop,
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model, &anthropic_normalize/3)
      assistant = Enum.find(result, &match?(%Message.Assistant{}, &1))

      text_blocks = Enum.filter(assistant.content, &match?(%Content.Text{}, &1))
      thinking_blocks = Enum.filter(assistant.content, &match?(%Content.Thinking{}, &1))

      assert thinking_blocks == []
      assert length(text_blocks) >= 2
    end
  end

  describe "tool call signatures — cross-model" do
    test "removes thought_signature from tool calls when migrating between models" do
      model = copilot_claude_model()

      messages = [
        user_msg("run a command"),
        copilot_assistant([
          %ToolCall{
            id: "call_123",
            name: "bash",
            arguments: %{"command" => "ls"},
            thought_signature: Jason.encode!(%{type: "reasoning.encrypted", id: "call_123", data: "encrypted"})
          }
        ]),
        tool_result("call_123", "bash", "output")
      ]

      result = TransformMessages.transform(messages, model, &anthropic_normalize/3)
      assistant = Enum.find(result, &match?(%Message.Assistant{}, &1))
      tool_call = Enum.find(assistant.content, &match?(%ToolCall{}, &1))

      assert tool_call.thought_signature == nil
    end
  end

  describe "orphaned tool calls" do
    test "adds synthetic tool results for trailing orphaned tool calls" do
      model = copilot_claude_model()

      messages = [
        user_msg("read the file"),
        copilot_assistant([
          %ToolCall{id: "call_123|fc_123", name: "read", arguments: %{"path" => "README.md"}}
        ])
      ]

      result = TransformMessages.transform(messages, model, &anthropic_normalize/3)
      last = List.last(result)

      assert %Message.ToolResult{} = last
      assert last.tool_call_id == "call_123_fc_123"
      assert last.tool_name == "read"
      assert last.is_error? == true
      assert last.content == [%Content.Text{text: "No result provided"}]
    end

    test "adds synthetic results only for tool calls still missing results" do
      model = copilot_claude_model()

      messages = [
        user_msg("run commands"),
        copilot_assistant([
          %ToolCall{id: "call_1|fc_1", name: "read", arguments: %{"path" => "README.md"}},
          %ToolCall{id: "call_2|fc_2", name: "bash", arguments: %{"command" => "pwd"}}
        ]),
        tool_result("call_1|fc_1", "read", "done")
      ]

      result = TransformMessages.transform(messages, model, &anthropic_normalize/3)
      synthetics = Enum.filter(result, &(match?(%Message.ToolResult{}, &1) and &1.is_error?))

      assert length(synthetics) == 1
      [synthetic] = synthetics
      assert synthetic.tool_call_id == "call_2_fc_2"
      assert synthetic.tool_name == "bash"
      assert synthetic.content == [%Content.Text{text: "No result provided"}]
    end
  end

  describe "image downgrade" do
    test "replaces images with placeholder for non-vision models" do
      model = %{copilot_claude_model() | input: [:text]}

      messages = [
        %Message.User{
          content: [
            %Content.Text{text: "look at this"},
            %Content.Image{data: "abc", mime_type: "image/png"},
            %Content.Image{data: "def", mime_type: "image/jpeg"},
            %Content.Text{text: "what do you see?"}
          ],
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model)
      [user] = result
      assert %Message.User{content: blocks} = user

      texts = Enum.map(blocks, & &1.text)

      assert texts == [
               "look at this",
               "(image omitted: model does not support images)",
               "what do you see?"
             ]
    end

    test "replaces tool result images with placeholder for non-vision models" do
      model = %{copilot_claude_model() | input: [:text]}

      messages = [
        %Message.ToolResult{
          tool_call_id: "tc1",
          tool_name: "read",
          content: [
            %Content.Text{text: "file content"},
            %Content.Image{data: "abc", mime_type: "image/png"}
          ],
          is_error?: false,
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model)
      [tr] = result
      texts = Enum.map(tr.content, & &1.text)
      assert texts == ["file content", "(tool image omitted: model does not support images)"]
    end

    test "preserves images for vision models" do
      model = copilot_claude_model()

      messages = [
        %Message.User{
          content: [
            %Content.Text{text: "look"},
            %Content.Image{data: "abc", mime_type: "image/png"}
          ],
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model)
      [user] = result
      assert length(user.content) == 2
      assert match?(%Content.Image{}, Enum.at(user.content, 1))
    end
  end

  describe "errored message skipping" do
    test "drops assistant messages with stop_reason :error" do
      model = copilot_claude_model()

      messages = [
        user_msg("hello"),
        %Message.Assistant{
          content: [%Content.Text{text: "partial"}],
          api: :openai_completions,
          provider: :github_copilot,
          model: "gpt-4o",
          usage: %Usage{},
          stop_reason: :error,
          timestamp: :os.system_time(:millisecond)
        },
        user_msg("retry")
      ]

      result = TransformMessages.transform(messages, model)
      assert length(result) == 2
      assert Enum.all?(result, &match?(%Message.User{}, &1))
    end

    test "drops assistant messages with stop_reason :aborted" do
      model = copilot_claude_model()

      messages = [
        user_msg("hello"),
        %Message.Assistant{
          content: [],
          api: :anthropic_messages,
          provider: :anthropic,
          model: "claude-sonnet-4",
          usage: %Usage{},
          stop_reason: :aborted,
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model)
      assert length(result) == 1
    end
  end

  describe "same-model preservation" do
    test "preserves thinking blocks with signatures for same model" do
      model = copilot_claude_model()

      messages = [
        user_msg("think"),
        %Message.Assistant{
          content: [
            %Content.Thinking{thinking: "deep thought", signature: "sig123"},
            %Content.Text{text: "answer"}
          ],
          api: :anthropic_messages,
          provider: :github_copilot,
          model: "claude-sonnet-4",
          usage: %Usage{},
          stop_reason: :stop,
          timestamp: :os.system_time(:millisecond)
        }
      ]

      result = TransformMessages.transform(messages, model)
      assistant = Enum.find(result, &match?(%Message.Assistant{}, &1))

      thinking = Enum.find(assistant.content, &match?(%Content.Thinking{}, &1))
      assert thinking
      assert thinking.thinking == "deep thought"
      assert thinking.signature == "sig123"
    end
  end
end
