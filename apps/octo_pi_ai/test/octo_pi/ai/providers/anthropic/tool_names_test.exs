defmodule OctoPi.AI.Providers.Anthropic.ToolNamesTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Providers.Anthropic.ToolNames
  alias OctoPi.AI.Tool

  # Anchors the frozen list — if the Claude Code tool table updates,
  # this test fails loudly so we notice.
  test "claude_code_tools lists the 17 CC 2.x tool names" do
    tools = ToolNames.claude_code_tools()
    assert length(tools) == 17
    assert "Read" in tools
    assert "TodoWrite" in tools
    assert "WebSearch" in tools
    refute "glob" in tools
  end

  describe "to_claude_code/1" do
    test "rewrites a lowercase name to CC casing" do
      assert ToolNames.to_claude_code("todowrite") == "TodoWrite"
      assert ToolNames.to_claude_code("read") == "Read"
      assert ToolNames.to_claude_code("websearch") == "WebSearch"
    end

    test "passes already-canonical names through unchanged" do
      assert ToolNames.to_claude_code("Read") == "Read"
      assert ToolNames.to_claude_code("TodoWrite") == "TodoWrite"
    end

    test "passes names that don't match any CC tool through unchanged" do
      assert ToolNames.to_claude_code("my_custom_tool") == "my_custom_tool"
      assert ToolNames.to_claude_code("UnknownTool") == "UnknownTool"
    end

    test "does not map find to Glob" do
      # Ported from pi-mono anthropic-tool-name-normalization.test.ts:112-163.
      # `find` and `Glob` are semantically similar but distinct tools;
      # rewriting `find` → `Glob` would break the round-trip since no
      # tool named `glob` would exist in the caller's context.
      assert ToolNames.to_claude_code("find") == "find"
    end
  end

  describe "from_claude_code/2" do
    test "restores original casing via case-insensitive match in tools list" do
      tools = [
        tool("todowrite"),
        tool("read")
      ]

      assert ToolNames.from_claude_code("TodoWrite", tools) == "todowrite"
      assert ToolNames.from_claude_code("Read", tools) == "read"
    end

    test "returns input unchanged when no tool matches" do
      tools = [tool("read"), tool("write")]
      assert ToolNames.from_claude_code("Glob", tools) == "Glob"
      assert ToolNames.from_claude_code("MissingTool", tools) == "MissingTool"
    end

    test "empty tools list passes through unchanged" do
      assert ToolNames.from_claude_code("Read", []) == "Read"
      assert ToolNames.from_claude_code("anything", []) == "anything"
    end

    test "returns the tool's exact original casing, not the CC name" do
      # Ported from pi-mono's round-trip test case.
      tools = [tool("my_custom_tool")]
      assert ToolNames.from_claude_code("my_custom_tool", tools) == "my_custom_tool"
    end
  end

  describe "round-trip" do
    test "todowrite → TodoWrite → todowrite" do
      tools = [tool("todowrite")]
      sent = ToolNames.to_claude_code("todowrite")
      received = ToolNames.from_claude_code(sent, tools)
      assert sent == "TodoWrite"
      assert received == "todowrite"
    end

    test "read → Read → read" do
      tools = [tool("read")]
      assert "Read" = sent = ToolNames.to_claude_code("read")
      assert "read" = ToolNames.from_claude_code(sent, tools)
    end

    test "find → find → find (not mapped)" do
      tools = [tool("find")]
      assert "find" = sent = ToolNames.to_claude_code("find")
      assert "find" = ToolNames.from_claude_code(sent, tools)
    end

    test "my_custom_tool → my_custom_tool → my_custom_tool" do
      tools = [tool("my_custom_tool")]
      assert "my_custom_tool" = sent = ToolNames.to_claude_code("my_custom_tool")
      assert "my_custom_tool" = ToolNames.from_claude_code(sent, tools)
    end
  end

  defp tool(name), do: %Tool{name: name, description: "", parameters: %{}}
end
