defmodule OctoPi.Agent.SubscribersTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Subscribers
  alias OctoPi.Agent.TestSupport.RecordingListener

  setup do
    # Use an arbitrary pid as the "session" key — Subscribers just
    # uses it as the Registry key, it doesn't need to be a real
    # session.
    {:ok, session: self()}
  end

  describe "subscribe/unsubscribe" do
    test "subscribe returns an unsubscribe closure", %{session: session} do
      unsubscribe = Subscribers.subscribe(session, self(), :async)
      assert Subscribers.count(session) == 1
      assert :ok = unsubscribe.()
      assert Subscribers.count(session) == 0
    end
  end

  describe ":sync dispatch" do
    test "calls listeners in registration order, awaits replies", %{session: session} do
      {:ok, first} = RecordingListener.start_link({self(), :first})
      {:ok, second} = RecordingListener.start_link({self(), :second})

      Subscribers.subscribe(session, first, :sync)
      Subscribers.subscribe(session, second, :sync)

      :ok = Subscribers.dispatch(session, %Event.AgentStart{})

      assert_received {:first, %Event.AgentStart{}}
      assert_received {:second, %Event.AgentStart{}}
    end

    test "logs and continues when a sync listener exits mid-dispatch", %{session: session} do
      # Bare dead pid → GenServer.call will :exit. Subscribers should
      # log a warning and still deliver to the second live listener.
      {dead, ref} = spawn_monitor(fn -> :ok end)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 100
      refute Process.alive?(dead)

      {:ok, live} = RecordingListener.start_link({self(), :live})

      Subscribers.subscribe(session, dead, :sync)
      Subscribers.subscribe(session, live, :sync)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          :ok = Subscribers.dispatch(session, %Event.AgentStart{})
        end)

      assert log =~ "sync listener"
      assert_received {:live, %Event.AgentStart{}}
    end
  end

  describe ":async dispatch" do
    test "sends without waiting", %{session: session} do
      Subscribers.subscribe(session, self(), :async)
      :ok = Subscribers.dispatch(session, %Event.AgentStart{})
      assert_received {:octo_pi_agent_event, %Event.AgentStart{}}
    end
  end
end
