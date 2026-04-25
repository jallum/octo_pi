defmodule OctoPi.Coder.Extensions.ProtectedPathsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.ProtectedPaths

  defp load_ext do
    {:ok, ext} = Loader.load_from_factory("protected-paths", &ProtectedPaths.init/1)
    ext
  end

  defp plain_ctx, do: Context.new(%{cwd: "/tmp"})

  defp dispatch(event, ctx \\ plain_ctx()) do
    ext = load_ext()
    [handler] = ext.handlers[:tool_call]
    handler.(event, ctx)
  end

  describe "init/1" do
    test "registers a tool_call handler" do
      ext = load_ext()
      assert Map.has_key?(ext.handlers, :tool_call)
      assert length(ext.handlers[:tool_call]) == 1
    end

    test "registers no tools" do
      ext = load_ext()
      assert ext.tools == %{}
    end

    test "registers no commands" do
      ext = load_ext()
      assert ext.commands == %{}
    end
  end

  describe "tool_call handler — blocking" do
    test "blocks write to .env" do
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => "/project/.env"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks edit to .env" do
      event = Event.new(:tool_call, %{name: "edit", arguments: %{"path" => "/project/.env"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks write inside .git/" do
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => ".git/config"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks write inside node_modules/" do
      event =
        Event.new(:tool_call, %{
          name: "write",
          arguments: %{"path" => "node_modules/lodash/index.js"}
        })

      assert {:block, _} = dispatch(event)
    end

    test "block reason mentions the path" do
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => ".env"}})
      {:block, reason} = dispatch(event)
      assert reason =~ ".env"
    end
  end

  describe "tool_call handler — allowing" do
    test "allows write to a safe path" do
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => "lib/my_module.ex"}})
      refute match?({:block, _}, dispatch(event))
    end

    test "allows bash tool regardless of command content" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "rm -rf .env"}})
      refute match?({:block, _}, dispatch(event))
    end

    test "allows read tool on protected path" do
      event = Event.new(:tool_call, %{name: "read", arguments: %{"path" => ".env"}})
      refute match?({:block, _}, dispatch(event))
    end
  end

  describe "tool_call handler — UI notification" do
    test "calls ui.notify when has_ui? is true and path is protected" do
      test_pid = self()
      ui = %UIContext{notify: fn msg -> send(test_pid, {:notify, msg}) end}
      ctx = Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => ".env"}})

      dispatch(event, ctx)

      assert_receive {:notify, msg}
      assert msg =~ ".env"
    end

    test "does not raise when has_ui? is false and path is protected" do
      event = Event.new(:tool_call, %{name: "write", arguments: %{"path" => ".env"}})
      assert {:block, _} = dispatch(event, plain_ctx())
    end
  end
end
