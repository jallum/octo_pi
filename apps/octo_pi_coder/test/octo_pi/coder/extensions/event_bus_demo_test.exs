defmodule OctoPi.Coder.Extensions.EventBusDemoTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.EventBus
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.EventBusDemo

  setup do
    {:ok, bus} = start_supervised(EventBus)
    %{bus: bus}
  end

  describe "init/2" do
    test "registers a session_start handler", %{bus: bus} do
      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      assert Map.has_key?(ext.handlers, :session_start)
      assert length(ext.handlers[:session_start]) == 1
    end

    test "registers an 'emit' command", %{bus: bus} do
      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      assert Map.has_key?(ext.commands, "emit")
    end

    test "'emit' command has the expected description", %{bus: bus} do
      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      assert ext.commands["emit"].description =~ "Emit"
    end

    test "registers no tools", %{bus: bus} do
      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      assert ext.tools == %{}
    end
  end

  describe "session_start handler" do
    test "emits a notification event on the bus when session starts", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "my:notification", fn data -> send(test_pid, {:notification, data}) end)

      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      handler = hd(ext.handlers[:session_start])
      handler.(%{type: :session_start, reason: :startup}, %{cwd: "/tmp"})

      assert_receive {:notification, data}
      assert data.message == "Session started"
      assert data.from == "event-bus-demo"
    end
  end

  describe "/emit command handler" do
    test "emits a notification with the given message", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "my:notification", fn data -> send(test_pid, {:notification, data}) end)

      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      ext.commands["emit"].handler.("hello world", nil)

      assert_receive {:notification, data}
      assert data.message == "hello world"
      assert data.from == "/emit command"
    end

    test "defaults to 'hello' when args are empty", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "my:notification", fn data -> send(test_pid, {:notification, data}) end)

      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      ext.commands["emit"].handler.("", nil)

      assert_receive {:notification, data}
      assert data.message == "hello"
    end

    test "trims whitespace from the message arg", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "my:notification", fn data -> send(test_pid, {:notification, data}) end)

      factory = fn api -> EventBusDemo.init(api, bus) end
      {:ok, ext} = Loader.load_from_factory("event-bus", factory)

      ext.commands["emit"].handler.("  hi  ", nil)

      assert_receive {:notification, data}
      assert data.message == "hi"
    end
  end

  describe "EventBus GenServer" do
    test "listener receives events emitted on its channel", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "test:event", fn data -> send(test_pid, {:got, data}) end)

      EventBus.emit(bus, "test:event", %{value: 42})

      assert_receive {:got, %{value: 42}}
    end

    test "listener does not receive events on other channels", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "channel:a", fn data -> send(test_pid, {:a, data}) end)

      EventBus.emit(bus, "channel:b", %{value: 1})

      refute_receive {:a, _}
    end

    test "unsubscribe function stops delivery", %{bus: bus} do
      test_pid = self()
      unsubscribe = EventBus.on(bus, "ch", fn data -> send(test_pid, {:got, data}) end)

      unsubscribe.()
      EventBus.emit(bus, "ch", %{value: 1})

      refute_receive {:got, _}
    end

    test "multiple listeners on same channel all receive the event", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "ch", fn _ -> send(test_pid, :first) end)
      EventBus.on(bus, "ch", fn _ -> send(test_pid, :second) end)

      EventBus.emit(bus, "ch", %{})

      assert_receive :first
      assert_receive :second
    end

    test "error in a listener does not crash the bus", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "ch", fn _ -> raise "boom" end)
      EventBus.on(bus, "ch", fn _ -> send(test_pid, :second_ran) end)

      EventBus.emit(bus, "ch", %{})

      assert_receive :second_ran
    end
  end
end
