defmodule OctoPi.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Message
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Usage

  defp assistant do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "claude-haiku-4-5",
      usage: %Usage{},
      stop_reason: :stop,
      timestamp: 0
    }
  end

  defp tool_result do
    %ToolResult{
      tool_call_id: "call_1",
      tool_name: "echo",
      content: [],
      is_error?: false,
      timestamp: 0
    }
  end

  describe "normalize/1" do
    test "wraps bare string in %User{}" do
      result = Message.normalize("hello")
      assert %User{content: "hello"} = result
      assert is_integer(result.timestamp)
    end

    test "passes %User{} through unchanged" do
      msg = %User{content: "hi", timestamp: 42}
      assert Message.normalize(msg) == msg
    end

    test "passes %Assistant{} through unchanged" do
      msg = assistant()
      assert Message.normalize(msg) == msg
    end

    test "passes %ToolResult{} through unchanged" do
      msg = tool_result()
      assert Message.normalize(msg) == msg
    end

    test "normalizes each element in a list" do
      msg = %User{content: "a", timestamp: 0}
      result = Message.normalize(["hello", msg])
      assert [%User{content: "hello"}, ^msg] = result
    end

    test "raises ArgumentError for unrecognized struct" do
      assert_raise ArgumentError, ~r/Expected Message\.t\(\)/, fn ->
        Message.normalize(%URI{})
      end
    end

    test "raises ArgumentError for integer" do
      assert_raise ArgumentError, ~r/Expected Message\.t\(\)/, fn ->
        Message.normalize(42)
      end
    end
  end

  describe "role/1" do
    test "returns :user for %User{}" do
      assert Message.role(%User{content: "hi", timestamp: 0}) == :user
    end

    test "returns :assistant for %Assistant{}" do
      assert Message.role(assistant()) == :assistant
    end

    test "returns :tool_result for %ToolResult{}" do
      assert Message.role(tool_result()) == :tool_result
    end
  end
end
