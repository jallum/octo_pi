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
    test "one-arity stubs raise before bind_core" do
      api = API.new("x")

      for field <- [
            :send_message,
            :send_user_message,
            :append_entry,
            :set_model,
            :set_thinking_level,
            :compact,
            :set_active_tools,
            :set_session_name,
            :set_label
          ] do
        assert_raise RuntimeError, ~r/not bound/, fn -> Map.get(api, field).(:arg) end
      end
    end

    test "zero-arity stubs raise before bind_core" do
      api = API.new("x")

      for field <- [
            :get_model,
            :get_thinking_level,
            :abort,
            :get_system_prompt,
            :get_active_tools,
            :get_all_tools,
            :get_session_name,
            :get_commands
          ] do
        assert_raise RuntimeError, ~r/not bound/, fn -> Map.get(api, field).() end
      end
    end

    test "two-arity stubs raise before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.exec.("tool", %{}) end
    end

    test "events.emit stub raises before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.events.emit.("ch", %{}) end
    end

    test "events.on stub raises before bind_core" do
      api = API.new("x")
      assert_raise RuntimeError, ~r/not bound/, fn -> api.events.on.("ch", fn _ -> nil end) end
    end
  end

  describe "bind_core/2" do
    test "replaces original action stubs with real implementations" do
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

    test "binds extended action methods" do
      api = API.new("x")

      actions = %{
        send_user_message: fn _text -> :user_sent end,
        append_entry: fn _entry -> :appended end,
        get_session_name: fn -> "my-session" end,
        set_session_name: fn _n -> :ok end,
        set_label: fn _l -> :ok end,
        exec: fn _tool, _args -> :executed end,
        get_all_tools: fn -> [:tool_a] end,
        get_commands: fn -> [:cmd_a] end
      }

      bound = API.bind_core(api, actions)
      assert :user_sent == bound.send_user_message.("hello")
      assert :appended == bound.append_entry.(%{})
      assert "my-session" == bound.get_session_name.()
      assert :ok == bound.set_session_name.("new")
      assert :ok == bound.set_label.("label")
      assert :executed == bound.exec.("bash", %{command: "ls"})
      assert [:tool_a] == bound.get_all_tools.()
      assert [:cmd_a] == bound.get_commands.()
    end
  end

  describe "bind_core/2 events" do
    test "binds events map from actions" do
      api = API.new("x")

      events = %{
        emit: fn _ch, _data -> :emitted end,
        on: fn _ch, _handler -> fn -> :off end end
      }

      bound = API.bind_core(api, %{events: events})
      assert :emitted == bound.events.emit.("ch", %{})
    end

    test "leaves events stub when actions has no events key" do
      api = API.new("x")
      bound = API.bind_core(api, %{})
      assert_raise RuntimeError, ~r/not bound/, fn -> bound.events.emit.("ch", %{}) end
    end
  end

  describe "register_provider/2 after bind_core" do
    test "returns error when already bound" do
      api = "x" |> API.new() |> API.bind_core(%{})
      config = %OctoPi.Coder.Extension.ProviderConfig{id: "p1", base_url: "https://a.com"}
      assert {:error, _reason} = API.register_provider(api, config)
    end
  end
end
