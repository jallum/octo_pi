defmodule OctoPi.Coder.ExtensionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension

  describe "new/2" do
    test "creates extension with id and path" do
      ext = Extension.new("my-ext", "/path/to/ext")
      assert ext.id == "my-ext"
      assert ext.path == "/path/to/ext"
      assert ext.handlers == %{}
      assert ext.tools == %{}
      assert ext.commands == %{}
    end
  end

  describe "add_handler/3" do
    test "registers handler for event type" do
      handler = fn _event, _ctx -> nil end
      ext = Extension.new("x", "/x") |> Extension.add_handler(:session_start, handler)

      assert [^handler] = Extension.get_handlers(ext, :session_start)
    end

    test "appends handlers in registration order" do
      h1 = fn _, _ -> :first end
      h2 = fn _, _ -> :second end

      ext =
        Extension.new("x", "/x")
        |> Extension.add_handler(:turn_start, h1)
        |> Extension.add_handler(:turn_start, h2)

      assert [^h1, ^h2] = Extension.get_handlers(ext, :turn_start)
    end

    test "rejects unknown event types" do
      handler = fn _, _ -> nil end
      assert_raise ArgumentError, ~r/unknown event type/, fn ->
        Extension.new("x", "/x") |> Extension.add_handler(:bogus_event, handler)
      end
    end
  end

  describe "get_handlers/2" do
    test "returns empty list for unregistered event" do
      ext = Extension.new("x", "/x")
      assert [] = Extension.get_handlers(ext, :session_start)
    end
  end

  describe "add_tool/2" do
    test "registers a tool by name" do
      tool = %{name: "my_tool", description: "test", input_schema: %{}}
      ext = Extension.new("x", "/x") |> Extension.add_tool(tool)

      assert ext.tools["my_tool"] == tool
    end
  end

  describe "add_command/3" do
    test "registers a command" do
      cmd = %{description: "do stuff", handler: fn _ -> :ok end}
      ext = Extension.new("x", "/x") |> Extension.add_command("do-stuff", cmd)

      assert ext.commands["do-stuff"] == cmd
    end
  end
end
