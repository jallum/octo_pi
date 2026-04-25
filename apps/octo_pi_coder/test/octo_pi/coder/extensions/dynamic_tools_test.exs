defmodule OctoPi.Coder.Extensions.DynamicToolsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.DynamicTools

  defp new_ext(register_tool_fn \\ fn _spec -> :ok end) do
    factory = fn api ->
      api
      |> API.bind_core(%{register_tool: register_tool_fn})
      |> DynamicTools.init()
    end

    {:ok, ext} = Loader.load_from_factory("dynamic-tools", factory)
    ext
  end

  describe "init/1" do
    test "registers echo_session tool" do
      ext = new_ext()
      assert Map.has_key?(ext.tools, "echo_session")
    end

    test "echo_session has expected description" do
      ext = new_ext()
      assert ext.tools["echo_session"].description =~ "session"
    end

    test "echo_session has a prompt_snippet" do
      ext = new_ext()
      assert is_binary(ext.tools["echo_session"].prompt_snippet)
    end

    test "echo_session has prompt_guidelines list" do
      ext = new_ext()
      guidelines = ext.tools["echo_session"].prompt_guidelines
      assert is_list(guidelines) and guidelines != []
    end

    test "registers an 'add-echo-tool' command" do
      ext = new_ext()
      assert Map.has_key?(ext.commands, "add-echo-tool")
    end

    test "'add-echo-tool' has expected description" do
      ext = new_ext()
      assert ext.commands["add-echo-tool"].description =~ "echo"
    end

    test "registers a session_start handler" do
      ext = new_ext()
      assert Map.has_key?(ext.handlers, :session_start)
      assert length(ext.handlers[:session_start]) == 1
    end
  end

  describe "echo_session tool" do
    test "execute returns prefixed message" do
      ext = new_ext()
      result = ext.tools["echo_session"].execute.(%{"message" => "hello"})
      assert hd(result.content).text =~ "hello"
      assert hd(result.content).text =~ "[session]"
    end

    test "execute includes tool name in details" do
      ext = new_ext()
      result = ext.tools["echo_session"].execute.(%{"message" => "test"})
      assert result.details.tool == "echo_session"
    end
  end

  describe "/add-echo-tool command" do
    test "calls api.register_tool with the tool spec for a valid name" do
      test_pid = self()

      ext =
        new_ext(fn spec ->
          send(test_pid, {:register, spec})
          :ok
        end)

      ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert_receive {:register, spec}
      assert spec.name == "my_tool"
    end

    test "returns success message for new tool" do
      ext = new_ext()
      result = ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert result =~ "my_tool"
    end

    test "returns warning for duplicate tool name" do
      ext = new_ext()
      ext.commands["add-echo-tool"].handler.("my_tool", nil)
      result = ext.commands["add-echo-tool"].handler.("my_tool", nil)
      assert result =~ "already"
    end

    test "returns error for empty name" do
      ext = new_ext()
      result = ext.commands["add-echo-tool"].handler.("", nil)
      assert result =~ "Usage"
    end

    test "returns error for name with invalid characters" do
      ext = new_ext()
      result = ext.commands["add-echo-tool"].handler.("bad-name!", nil)
      assert result =~ "Usage"
    end

    test "does not call api.register_tool for invalid name" do
      test_pid = self()

      ext =
        new_ext(fn spec ->
          send(test_pid, {:register, spec})
          :ok
        end)

      ext.commands["add-echo-tool"].handler.("bad name", nil)
      refute_receive {:register, _}
    end
  end

  describe "session_start handler" do
    test "sends notification when has_ui? is true" do
      test_pid = self()
      ui = UIContext.bind(UIContext.new(), %{notify: fn msg -> send(test_pid, {:notify, msg}) end})
      ctx = Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})

      ext = new_ext()
      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      handler.(event, ctx)

      assert_receive {:notify, msg}
      assert msg =~ "echo_session"
    end

    test "does not raise when has_ui? is false" do
      ext = new_ext()
      ctx = Context.new(%{cwd: "/tmp"})
      handler = hd(ext.handlers[:session_start])
      event = Event.new(:session_start, %{reason: :startup})
      assert handler.(event, ctx) == :ok
    end
  end

  describe "echo_session pre-registered in internal registry" do
    test "adding echo_session again returns duplicate warning" do
      ext = new_ext()
      result = ext.commands["add-echo-tool"].handler.("echo_session", nil)
      assert result =~ "already"
    end
  end
end
