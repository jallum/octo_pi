defmodule OctoPi.Coder.Extension.ToolRenderTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.ToolRender

  describe "Context struct" do
    test "has expected defaults" do
      ctx = %ToolRender.Context{}
      assert ctx.args == %{}
      assert ctx.execution_started == false
      assert ctx.is_partial == false
      assert ctx.expanded == false
    end

    test "accepts all fields" do
      ctx = %ToolRender.Context{
        args: %{command: "ls"},
        tool_call_id: "tc-123",
        cwd: "/home",
        execution_started: true,
        args_complete: true,
        is_partial: false,
        expanded: true,
        show_images: true,
        is_error: false,
        state: :running,
        invalidate: fn -> :ok end,
        last_component: nil
      }

      assert ctx.args.command == "ls"
      assert ctx.execution_started
      assert ctx.state == :running
    end
  end

  describe "merge_into_tool/2" do
    test "merges render options into tool map" do
      tool = %{name: "my_tool", description: "test", input_schema: %{}}
      render_call = fn _ctx -> "custom call render" end
      render_result = fn _ctx -> "custom result render" end

      merged = ToolRender.merge_into_tool(tool, %{
        render_call: render_call,
        render_result: render_result,
        render_shell: :self,
        execution_mode: :sequential,
        prompt_snippet: "Use my_tool for X",
        prompt_guidelines: ["Always pass --verbose", "Never use without args"]
      })

      assert merged.name == "my_tool"
      assert merged.render_call == render_call
      assert merged.render_result == render_result
      assert merged.render_shell == :self
      assert merged.execution_mode == :sequential
      assert merged.prompt_snippet == "Use my_tool for X"
      assert merged.prompt_guidelines == ["Always pass --verbose", "Never use without args"]
    end

    test "ignores unknown keys" do
      tool = %{name: "t", description: "d", input_schema: %{}}
      merged = ToolRender.merge_into_tool(tool, %{bogus: true, render_shell: :default})

      refute Map.has_key?(merged, :bogus)
      assert merged.render_shell == :default
    end

    test "prepareArguments shim" do
      tool = %{name: "t", description: "d", input_schema: %{}}
      prep = fn args -> Map.put(args, :sanitized, true) end

      merged = ToolRender.merge_into_tool(tool, %{prepare_arguments: prep})
      assert merged.prepare_arguments.(%{command: "rm"}).sanitized
    end
  end
end
