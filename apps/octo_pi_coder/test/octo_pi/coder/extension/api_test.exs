defmodule OctoPi.Coder.Extension.APITest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API

  describe "new/1" do
    test "creates API with extension ref" do
      api = API.new("my-ext")
      assert api.extension_id == "my-ext"
    end
  end

  describe "on/3" do
    test "registers a handler for an event type" do
      api = API.new("x")
      handler = fn _e, _c -> nil end
      assert {:ok, api} = API.on(api, :session_start, handler)
      assert [{:session_start, ^handler}] = api.registered_handlers
    end

    test "accumulates handlers in order" do
      h1 = fn _, _ -> :first end
      h2 = fn _, _ -> :second end

      api = API.new("x")
      {:ok, api} = API.on(api, :session_start, h1)
      {:ok, api} = API.on(api, :turn_start, h2)

      assert [{:session_start, ^h1}, {:turn_start, ^h2}] = api.registered_handlers
    end

    test "rejects unknown event types" do
      api = API.new("x")
      assert {:error, _} = API.on(api, :fake_event, fn _, _ -> nil end)
    end
  end

  describe "register_tool/2" do
    test "registers a tool" do
      api = API.new("x")
      tool = %{name: "my_tool", description: "test", input_schema: %{}}
      {:ok, api} = API.register_tool(api, tool)
      assert [^tool] = api.registered_tools
    end
  end

  describe "register_command/3" do
    test "registers a command" do
      api = API.new("x")
      cmd = %{description: "do stuff", handler: fn _ -> :ok end}
      {:ok, api} = API.register_command(api, "do-stuff", cmd)
      assert [{"do-stuff", ^cmd}] = api.registered_commands
    end
  end

  describe "build_extension/2" do
    test "builds Extension struct from API registrations" do
      h1 = fn _, _ -> nil end
      h2 = fn _, _ -> nil end
      tool = %{name: "my_tool", description: "test", input_schema: %{}}
      cmd = %{description: "do stuff", handler: fn _ -> :ok end}

      api = API.new("my-ext")
      {:ok, api} = API.on(api, :session_start, h1)
      {:ok, api} = API.on(api, :session_start, h2)
      {:ok, api} = API.register_tool(api, tool)
      {:ok, api} = API.register_command(api, "do-it", cmd)

      ext = API.build_extension(api, "/path/to/ext")

      assert ext.id == "my-ext"
      assert ext.path == "/path/to/ext"
      assert [^h1, ^h2] = ext.handlers[:session_start]
      assert ext.tools["my_tool"] == tool
      assert ext.commands["do-it"] == cmd
    end
  end

  describe "action stubs" do
    test "send_message raises before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.send_message.("hi") end
    end

    test "get_model raises before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.get_model.() end
    end

    test "abort raises before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.abort.() end
    end
  end

  describe "bind_core/2" do
    test "replaces action stubs with real implementations" do
      api = API.new("x")

      actions = %{
        send_message: fn _text -> :sent end,
        get_model: fn -> %{id: "test"} end,
        set_model: fn _m -> :ok end,
        get_thinking_level: fn -> "medium" end,
        set_thinking_level: fn _l -> :ok end,
        abort: fn -> :aborted end,
        compact: fn _opts -> :compacted end,
        get_system_prompt: fn -> "prompt" end,
        get_active_tools: fn -> [] end,
        set_active_tools: fn _t -> :ok end
      }

      bound = API.bind_core(api, actions)
      assert :sent == bound.send_message.("hi")
      assert %{id: "test"} == bound.get_model.()
      assert :aborted == bound.abort.()
    end
  end
end
