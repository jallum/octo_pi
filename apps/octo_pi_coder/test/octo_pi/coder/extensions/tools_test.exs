defmodule OctoPi.Coder.Extensions.ToolsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.Tools
  alias OctoPi.Coder.Session.Entry.Custom, as: CustomEntry

  defp all_tools do
    [
      %{name: "bash", label: "Bash"},
      %{name: "write", label: "Write"},
      %{name: "read", label: "Read"}
    ]
  end

  defp ext_with_state(initial_active \\ ["bash", "write"]) do
    {:ok, state} = Agent.start_link(fn -> %{enabled_tools: MapSet.new(initial_active)} end)

    applied = fn -> [] end |> Agent.start_link() |> elem(1)

    factory = fn api ->
      api =
        API.bind_core(api, %{
          get_all_tools: fn -> all_tools() end,
          get_active_tools: fn -> Enum.filter(all_tools(), &(&1.name in initial_active)) end,
          set_active_tools: fn tools ->
            Agent.update(applied, fn _ -> tools end)
            :ok
          end,
          append_entry: fn _ -> :ok end
        })

      Tools.init(api, state)
    end

    {:ok, ext} = Loader.load_from_factory("tools", factory)
    {ext, state, applied}
  end

  defp ctx(entries \\ []), do: Context.new(%{cwd: "/tmp", get_entries: fn -> entries end})

  defp ctx_with_ui(custom_calls, entries \\ []) do
    ui = %UIContext{
      custom: fn factory, _opts ->
        Agent.update(custom_calls, fn acc -> [factory | acc] end)
        nil
      end
    }

    Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui, get_entries: fn -> entries end})
  end

  defp call_factory(custom_calls) do
    [factory] = Agent.get(custom_calls, & &1)
    tui = %{request_render: fn -> :ok end}
    theme = %{fg: fn _color, text -> text end}
    {:ok, done_box} = Agent.start_link(fn -> nil end)
    done = fn result -> Agent.update(done_box, fn _ -> result end) end
    component = factory.(tui, theme, done)
    {component, done_box}
  end

  defp tools_config_entry(names),
    do: %CustomEntry{
      id: "test-#{:erlang.unique_integer([:positive])}",
      timestamp: "2026-04-26T00:00:00Z",
      custom_type: "tools_config",
      data: %{"enabled_tools" => names}
    }

  describe "init/2" do
    test "registers a 'tools' command" do
      {ext, _, _} = ext_with_state()
      assert Map.has_key?(ext.commands, "tools")
    end

    test "'tools' has expected description" do
      {ext, _, _} = ext_with_state()
      assert ext.commands["tools"].description =~ "tool"
    end

    test "registers a session_start handler" do
      {ext, _, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :session_start)
      assert length(ext.handlers[:session_start]) == 1
    end

    test "registers a session_tree handler" do
      {ext, _, _} = ext_with_state()
      assert Map.has_key?(ext.handlers, :session_tree)
      assert length(ext.handlers[:session_tree]) == 1
    end

    test "registers no extra tools" do
      {ext, _, _} = ext_with_state()
      assert ext.tools == %{}
    end
  end

  describe "session_start handler" do
    test "loads active tool names into state when no branch config" do
      {ext, state, _} = ext_with_state(["bash"])

      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      handler.(event, ctx())

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.member?(enabled, "bash")
    end

    test "removes previously enabled tools not in active set when no branch config" do
      {ext, state, _} = ext_with_state(["bash"])

      Agent.update(state, fn s -> %{s | enabled_tools: MapSet.new(["bash", "write", "read"])} end)

      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx())

      enabled = Agent.get(state, & &1.enabled_tools)
      refute MapSet.member?(enabled, "write")
      refute MapSet.member?(enabled, "read")
    end

    test "restores enabled tools from branch tools-config entry" do
      {ext, state, _} = ext_with_state(["bash", "write"])

      branch = [tools_config_entry(["read"])]
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx(branch))

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.equal?(enabled, MapSet.new(["read"]))
    end

    test "uses the last tools-config entry when branch has multiple" do
      {ext, state, _} = ext_with_state(["bash"])

      branch = [tools_config_entry(["bash"]), tools_config_entry(["read", "write"])]
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx(branch))

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.equal?(enabled, MapSet.new(["read", "write"]))
    end

    test "filters out tool names not in get_all_tools when restoring from branch" do
      {ext, state, _} = ext_with_state(["bash"])

      branch = [tools_config_entry(["read", "nonexistent_tool"])]
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx(branch))

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.equal?(enabled, MapSet.new(["read"]))
      refute MapSet.member?(enabled, "nonexistent_tool")
    end

    test "calls set_active_tools with restored tool names" do
      {ext, _, applied} = ext_with_state(["bash"])

      branch = [tools_config_entry(["read"])]
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx(branch))

      applied_names = Agent.get(applied, & &1)
      assert applied_names == ["read"]
    end
  end

  describe "session_tree handler" do
    test "reloads active tool names into state" do
      {ext, state, _} = ext_with_state(["write"])

      handler = hd(ext.handlers[:session_tree])
      event = Event.new(:session_tree, %{})
      handler.(event, ctx())

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.member?(enabled, "write")
    end
  end

  describe "/tools command — interactive UI (has_ui?: true)" do
    test "calls ctx.ui.custom with a 3-arity factory fn" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      ctx = ctx_with_ui(custom_calls)
      {ext, _, _} = ext_with_state()
      ext.commands["tools"].handler.("", ctx)
      [factory] = Agent.get(custom_calls, & &1)
      assert is_function(factory, 3)
    end

    test "factory returns a component with render and handle_input fns" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _, _} = ext_with_state()
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, _} = call_factory(custom_calls)
      assert is_function(component.render, 1)
      assert is_function(component.handle_input, 1)
    end

    test "render fn returns lines containing each tool name" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _, _} = ext_with_state(["bash"])
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, _} = call_factory(custom_calls)
      lines = component.render.(80)
      assert is_list(lines)
      assert Enum.any?(lines, &String.contains?(&1, "bash"))
      assert Enum.any?(lines, &String.contains?(&1, "write"))
      assert Enum.any?(lines, &String.contains?(&1, "read"))
    end

    test "render fn reflects enabled status" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _, _} = ext_with_state(["bash"])
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, _} = call_factory(custom_calls)
      lines = component.render.(80)
      bash_line = Enum.find(lines, &String.contains?(&1, "bash"))
      assert bash_line =~ "enabled"
      read_line = Enum.find(lines, &String.contains?(&1, "read"))
      assert read_line =~ "disabled"
    end

    test "escape key calls done with nil" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _, _} = ext_with_state()
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, done_box} = call_factory(custom_calls)
      component.handle_input.({:key, %{key: :escape}})
      assert Agent.get(done_box, & &1) == nil
    end

    test "enter toggles selected tool and calls set_active_tools" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _state, applied} = ext_with_state(["bash", "write"])
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, _} = call_factory(custom_calls)
      # Default selection is 0 (bash). Enter disables it.
      component.handle_input.({:key, %{key: :enter}})
      applied_names = Agent.get(applied, & &1)
      refute "bash" in applied_names
    end

    test "down key moves selection and enter toggles newly selected tool" do
      {:ok, custom_calls} = Agent.start_link(fn -> [] end)
      {ext, _state, applied} = ext_with_state(["bash"])
      ext.commands["tools"].handler.("", ctx_with_ui(custom_calls))
      {component, _} = call_factory(custom_calls)
      # Move to "write" (index 1), then toggle
      component.handle_input.({:key, %{key: :down}})
      component.handle_input.({:key, %{key: :enter}})
      applied_names = Agent.get(applied, & &1)
      assert "write" in applied_names
    end
  end

  describe "/tools command — no-UI fallback (has_ui?: false)" do
    test "returns a list of tool status maps" do
      {ext, _, _} = ext_with_state(["bash"])

      result = ext.commands["tools"].handler.("", ctx())

      assert is_list(result)
      assert length(result) == length(all_tools())
    end

    test "enabled tools are marked as enabled in the result" do
      {ext, _, _} = ext_with_state(["bash"])

      result = ext.commands["tools"].handler.("", ctx())
      bash = Enum.find(result, &(&1.name == "bash"))
      assert bash.enabled == true
    end

    test "inactive tools are marked as disabled in the result" do
      {ext, _, _} = ext_with_state(["bash"])

      result = ext.commands["tools"].handler.("", ctx())
      read = Enum.find(result, &(&1.name == "read"))
      assert read.enabled == false
    end

    test "result reflects state updated by session_start handler" do
      {ext, _, _} = ext_with_state(["read"])

      session_handler = hd(ext.handlers[:session_start])
      session_handler.(Event.new(:session_start, %{reason: :startup}), ctx())

      result = ext.commands["tools"].handler.("", ctx())
      read = Enum.find(result, &(&1.name == "read"))
      assert read.enabled == true
    end
  end
end
