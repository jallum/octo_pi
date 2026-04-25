defmodule OctoPi.Coder.Extension.EventBusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias OctoPi.Coder.Extension.EventBus

  setup do
    {:ok, bus} = EventBus.start_link([])
    {:ok, bus: bus}
  end

  describe "emit/on" do
    test "delivers messages to subscribers", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "my:channel", fn data -> send(test_pid, {:got, data}) end)

      EventBus.emit(bus, "my:channel", %{hello: :world})
      assert_receive {:got, %{hello: :world}}
    end

    test "delivers to multiple subscribers", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "ch", fn data -> send(test_pid, {:a, data}) end)
      EventBus.on(bus, "ch", fn data -> send(test_pid, {:b, data}) end)

      EventBus.emit(bus, "ch", :payload)
      assert_receive {:a, :payload}
      assert_receive {:b, :payload}
    end

    test "different channels are isolated", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "ch1", fn _ -> send(test_pid, :ch1) end)
      EventBus.on(bus, "ch2", fn _ -> send(test_pid, :ch2) end)

      EventBus.emit(bus, "ch1", nil)
      assert_receive :ch1
      refute_receive :ch2
    end

    test "no subscribers is a no-op", %{bus: bus} do
      assert :ok = EventBus.emit(bus, "empty", :data)
    end
  end

  describe "unsubscribe" do
    test "returned function removes subscriber", %{bus: bus} do
      test_pid = self()
      unsub = EventBus.on(bus, "ch", fn _ -> send(test_pid, :got_it) end)

      unsub.()
      EventBus.emit(bus, "ch", :data)
      refute_receive :got_it
    end
  end

  describe "clear/1" do
    test "removes all subscribers", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "a", fn _ -> send(test_pid, :a) end)
      EventBus.on(bus, "b", fn _ -> send(test_pid, :b) end)

      EventBus.clear(bus)

      EventBus.emit(bus, "a", nil)
      EventBus.emit(bus, "b", nil)
      refute_receive :a
      refute_receive :b
    end
  end

  describe "error isolation" do
    test "handler error does not crash bus or affect other handlers", %{bus: bus} do
      test_pid = self()
      EventBus.on(bus, "ch", fn _ -> raise "boom" end)
      EventBus.on(bus, "ch", fn _ -> send(test_pid, :survived) end)

      log =
        capture_log(fn ->
          EventBus.emit(bus, "ch", :data)
          assert_receive :survived
        end)

      assert log =~ "EventBus handler error on ch: boom"
    end
  end
end
