defmodule OctoPi.Coder.Extensions.ToolsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.Tools

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

  defp ctx, do: Context.new(%{cwd: "/tmp"})

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
    test "loads active tool names into state" do
      {ext, state, _} = ext_with_state(["bash"])

      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      handler.(event, ctx())

      enabled = Agent.get(state, & &1.enabled_tools)
      assert MapSet.member?(enabled, "bash")
    end

    test "removes previously enabled tools not in active set" do
      {ext, state, _} = ext_with_state(["bash"])

      Agent.update(state, fn s -> %{s | enabled_tools: MapSet.new(["bash", "write", "read"])} end)

      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx())

      enabled = Agent.get(state, & &1.enabled_tools)
      refute MapSet.member?(enabled, "write")
      refute MapSet.member?(enabled, "read")
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

  describe "/tools command" do
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
