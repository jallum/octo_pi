defmodule OctoPi.Coder.Extensions.PermissionGateTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.PermissionGate

  defp load_ext do
    {:ok, ext} = Loader.load_from_factory("permission-gate", &PermissionGate.init/1)
    ext
  end

  defp no_ui_ctx, do: Context.new(%{cwd: "/tmp"})

  defp dispatch(event, ctx \\ no_ui_ctx()) do
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

  describe "tool_call handler — no UI (block dangerous by default)" do
    test "blocks rm -rf command" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "rm -rf /tmp/foo"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks rm -r command" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "rm -r /tmp/foo"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks sudo command" do
      event =
        Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "sudo apt-get install curl"}})

      assert {:block, _} = dispatch(event)
    end

    test "blocks chmod 777 command" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "chmod 777 file.sh"}})
      assert {:block, _} = dispatch(event)
    end

    test "blocks chown 777 command" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "chown 777 file.sh"}})
      assert {:block, _} = dispatch(event)
    end

    test "block reason mentions no UI" do
      event =
        Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "sudo rm -rf /"}})

      {:block, reason} = dispatch(event)
      assert reason =~ "no UI"
    end

    test "allows safe bash command" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "ls -la"}})
      refute match?({:block, _}, dispatch(event))
    end

    test "allows write tool even with dangerous-looking content" do
      event =
        Event.new(:tool_call, %{
          name: "write",
          arguments: %{"path" => ".env", "content" => "sudo=false"}
        })

      refute match?({:block, _}, dispatch(event))
    end
  end

  describe "tool_call handler — with UI" do
    defp ui_ctx(choice) do
      ui = %UIContext{select: fn _opts, _kw -> {:ok, choice} end}
      Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
    end

    test "allows command when user selects :yes" do
      ctx = ui_ctx(:yes)
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "sudo ls"}})
      refute match?({:block, _}, dispatch(event, ctx))
    end

    test "blocks command when user selects :no" do
      ctx = ui_ctx(:no)
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "sudo ls"}})
      assert {:block, _} = dispatch(event, ctx)
    end

    test "block reason mentions user when user declines" do
      ctx = ui_ctx(:no)
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "sudo ls"}})
      {:block, reason} = dispatch(event, ctx)
      assert reason =~ "user"
    end

    test "safe command bypasses UI prompt entirely" do
      event = Event.new(:tool_call, %{name: "bash", arguments: %{"command" => "echo hello"}})
      ctx = ui_ctx(:no)
      refute match?({:block, _}, dispatch(event, ctx))
    end
  end
end
