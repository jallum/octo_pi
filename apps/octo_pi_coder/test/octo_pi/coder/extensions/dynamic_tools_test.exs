defmodule OctoPi.Coder.Extensions.DynamicToolsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.DynamicTools

  defp ext_with_registry do
    {:ok, registry} = Agent.start_link(fn -> MapSet.new() end)

    factory = fn api -> DynamicTools.init(api, registry) end
    {:ok, ext} = Loader.load_from_factory("dynamic-tools", factory)
    {ext, registry}
  end

  describe "init/2" do
    test "registers echo_session tool" do
      {ext, _} = ext_with_registry()
      assert Map.has_key?(ext.tools, "echo_session")
    end

    test "echo_session has expected description" do
      {ext, _} = ext_with_registry()
      assert ext.tools["echo_session"].description =~ "session"
    end

    test "echo_session has a prompt_snippet" do
      {ext, _} = ext_with_registry()
      assert is_binary(ext.tools["echo_session"].prompt_snippet)
    end

    test "echo_session has prompt_guidelines list" do
      {ext, _} = ext_with_registry()
      guidelines = ext.tools["echo_session"].prompt_guidelines
      assert is_list(guidelines) and guidelines != []
    end

    test "registers an 'add-echo-tool' command" do
      {ext, _} = ext_with_registry()
      assert Map.has_key?(ext.commands, "add-echo-tool")
    end

    test "'add-echo-tool' has expected description" do
      {ext, _} = ext_with_registry()
      assert ext.commands["add-echo-tool"].description =~ "echo"
    end

    test "registers a session_start handler" do
      {ext, _} = ext_with_registry()
      assert Map.has_key?(ext.handlers, :session_start)
      assert length(ext.handlers[:session_start]) == 1
    end
  end

  describe "echo_session tool" do
    test "execute returns prefixed message" do
      {ext, _} = ext_with_registry()
      result = ext.tools["echo_session"].execute.(%{"message" => "hello"})
      assert hd(result.content).text =~ "hello"
      assert hd(result.content).text =~ "[session]"
    end

    test "execute includes tool name in details" do
      {ext, _} = ext_with_registry()
      result = ext.tools["echo_session"].execute.(%{"message" => "test"})
      assert result.details.tool == "echo_session"
    end
  end

  describe "/add-echo-tool command" do
    test "tracks a valid tool name in the registry" do
      {ext, registry} = ext_with_registry()
      ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert MapSet.member?(Agent.get(registry, & &1), "my_tool")
    end

    test "returns success message for new tool" do
      {ext, _} = ext_with_registry()
      result = ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert result =~ "my_tool"
    end

    test "returns warning for duplicate tool name" do
      {ext, _} = ext_with_registry()
      ext.commands["add-echo-tool"].handler.("my_tool", nil)
      result = ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert result =~ "already"
    end

    test "returns error for empty name" do
      {ext, _} = ext_with_registry()
      result = ext.commands["add-echo-tool"].handler.("", nil)
      assert result =~ "Usage"
    end

    test "returns error for name with invalid characters" do
      {ext, _} = ext_with_registry()
      result = ext.commands["add-echo-tool"].handler.("bad-name!", nil)
      assert result =~ "Usage"
    end

    test "does not add invalid name to registry" do
      {ext, registry} = ext_with_registry()
      ext.commands["add-echo-tool"].handler.("bad name", nil)
      refute MapSet.member?(Agent.get(registry, & &1), "bad name")
    end
  end

  describe "session_start handler" do
    test "sends notification when has_ui? is true" do
      test_pid = self()
      ui = %UIContext{notify: fn msg -> send(test_pid, {:notify, msg}) end}
      ctx = Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})

      {:ok, registry} = Agent.start_link(fn -> MapSet.new() end)
      factory = fn api -> DynamicTools.init(api, registry) end
      {:ok, ext} = Loader.load_from_factory("dynamic-tools", factory)

      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      handler.(event, ctx)

      assert_receive {:notify, msg}
      assert msg =~ "echo_session"
    end

    test "does not raise when has_ui? is false" do
      {ext, _} = ext_with_registry()
      ctx = Context.new(%{cwd: "/tmp"})
      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      assert handler.(event, ctx) == :ok
    end
  end

  describe "echo_session pre-registered in registry" do
    test "echo_session is already in registry at init time" do
      {_ext, registry} = ext_with_registry()
      assert MapSet.member?(Agent.get(registry, & &1), "echo_session")
    end

    test "adding echo_session again returns duplicate warning" do
      {ext, _} = ext_with_registry()
      result = ext.commands["add-echo-tool"].handler.("echo_session", nil)
      assert result =~ "already"
    end
  end
end
