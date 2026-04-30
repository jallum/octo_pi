defmodule OctoPi.Agent.MessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Message
  alias OctoPi.AI.Content.Text
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
    # opi-5ka.1: every User.t() / ToolResult.t() returned by normalize/1
    # has list-shape content. Bare strings and string-content structs
    # are lifted to [%Text{text: ...}].
    test "wraps bare string in %User{} with lifted [%Text{}] content" do
      result = Message.normalize("hello")
      assert %User{content: [%Text{text: "hello"}]} = result
      assert is_integer(result.timestamp)
    end

    test "lifts %User{} string content to [%Text{}]" do
      msg = %User{content: "hi", timestamp: 42}
      result = Message.normalize(msg)
      assert %User{content: [%Text{text: "hi"}], timestamp: 42} = result
    end

    test "passes %User{} list content through unchanged" do
      msg = %User{content: [%Text{text: "a"}, %Text{text: "b"}], timestamp: 42}
      assert Message.normalize(msg) == msg
    end

    test "passes %Assistant{} through unchanged" do
      msg = assistant()
      assert Message.normalize(msg) == msg
    end

    test "lifts %ToolResult{} string content to [%Text{}]" do
      msg = %ToolResult{
        tool_call_id: "call_1",
        tool_name: "echo",
        content: "output",
        is_error?: false,
        timestamp: 0
      }

      result = Message.normalize(msg)
      assert %ToolResult{content: [%Text{text: "output"}]} = result
    end

    test "passes %ToolResult{} list content through unchanged" do
      msg = tool_result()
      assert Message.normalize(msg) == msg
    end

    test "normalizes each element in a list, lifting strings as needed" do
      msg = %User{content: "a", timestamp: 0}
      result = Message.normalize(["hello", msg])

      assert [
               %User{content: [%Text{text: "hello"}]},
               %User{content: [%Text{text: "a"}], timestamp: 0}
             ] = result
    end

    test "raises ArgumentError for unrecognized input" do
      assert_raise ArgumentError, ~r/Expected Message\.t\(\)/, fn ->
        Message.normalize(%URI{})
      end
    end
  end

  describe "normalize_if_message/1" do
    test "lifts User binary content; passes Assistant / ToolResult / synthetic terms through" do
      synthetic_map = %{"role" => "compactionSummary", "summary" => "x"}
      assistant_msg = assistant()
      tool_result_msg = tool_result()

      assert %User{content: [%Text{text: "hi"}]} =
               Message.normalize_if_message(%User{content: "hi", timestamp: 0})

      assert Message.normalize_if_message(assistant_msg) == assistant_msg
      assert Message.normalize_if_message(tool_result_msg) == tool_result_msg
      assert Message.normalize_if_message(synthetic_map) == synthetic_map
      assert Message.normalize_if_message("a-bare-string") == "a-bare-string"
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
