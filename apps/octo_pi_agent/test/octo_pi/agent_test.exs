defmodule OctoPi.AgentTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.{Content, Message.Assistant, Model}

  alias OctoPi.Agent.{
    AbortRef,
    Event,
    Message,
    PendingMessageQueue,
    Session,
    Tool,
    Transport
  }

  alias OctoPi.Agent.TestSupport.EchoTool

  describe "contract structs" do
    test "Message union types include User/Assistant/ToolResult/Custom" do
      assert %Message.Custom{kind: :note, payload: %{msg: "x"}, timestamp: 0}
      # User / Assistant / ToolResult are reused from octo_pi_ai;
      # see OctoPi.AITest for construction assertions.
    end

    test "Event structs exist for the full lifecycle" do
      partial = %Assistant{
        api: :anthropic_messages,
        provider: :anthropic,
        model: "claude",
        timestamp: 0
      }

      assert %Event.AgentStart{}
      assert %Event.AgentEnd{reason: :stop, messages: []}
      assert %Event.TurnStart{turn: 1}
      assert %Event.TurnEnd{turn: 1}
      assert %Event.MessageStart{partial: partial}
      assert %Event.MessageUpdate{partial: partial}
      assert %Event.MessageEnd{message: partial}
      assert %Event.ToolExecutionStart{tool_call_id: "x", tool_name: "echo"}

      assert %Event.ToolExecutionUpdate{
        tool_call_id: "x",
        partial: %Tool.Result{content: []}
      }

      assert %Event.ToolExecutionEnd{
        tool_call_id: "x",
        tool_name: "echo",
        result: %Tool.Result{content: []}
      }
    end

    test "Tool struct defaults execution_mode to :parallel" do
      assert %Tool{execution_mode: :parallel} = EchoTool.tool()
    end

    test "Tool.Result defaults: no error, no terminate, nil details" do
      assert %Tool.Result{is_error?: false, terminate?: false, details: nil} =
               %Tool.Result{content: []}
    end

    test "Session.State enforces :model and :transport" do
      state = %Session.State{
        model: fake_model(),
        transport: Transport.Direct
      }

      assert state.tools == []
      assert state.messages == []
      refute state.is_streaming?
      assert state.pending_tool_calls == MapSet.new()
      assert %PendingMessageQueue{count: 0, mode: :one_at_a_time} = state.steering_queue
    end

    test "PendingMessageQueue.new/2 accepts mode + bound" do
      q = PendingMessageQueue.new(:all, 5)
      assert q.mode == :all
      assert q.bound == 5
      assert PendingMessageQueue.empty?(q)
    end
  end

  describe "PendingMessageQueue behaviour" do
    alias OctoPi.AI.Message.User

    defp user(text), do: %User{content: text, timestamp: 0}

    test "enqueue appends and updates count" do
      q = PendingMessageQueue.new()
      assert {:ok, q} = PendingMessageQueue.enqueue(q, user("a"))
      assert q.count == 1
      assert PendingMessageQueue.has_items?(q)
    end

    test "enqueue beyond bound returns {:error, :full}" do
      q = PendingMessageQueue.new(:one_at_a_time, 2)
      assert {:ok, q} = PendingMessageQueue.enqueue(q, user("a"))
      assert {:ok, q} = PendingMessageQueue.enqueue(q, user("b"))
      assert {:error, :full} = PendingMessageQueue.enqueue(q, user("c"))
    end

    test "drain :one_at_a_time returns head, leaves rest" do
      q = PendingMessageQueue.new(:one_at_a_time)
      {:ok, q} = PendingMessageQueue.enqueue(q, user("a"))
      {:ok, q} = PendingMessageQueue.enqueue(q, user("b"))
      {drained, q} = PendingMessageQueue.drain(q)
      assert [%User{content: "a"}] = drained
      assert q.count == 1
    end

    test "drain :all returns everything, clears queue" do
      q = PendingMessageQueue.new(:all)
      {:ok, q} = PendingMessageQueue.enqueue(q, user("a"))
      {:ok, q} = PendingMessageQueue.enqueue(q, user("b"))
      {drained, q} = PendingMessageQueue.drain(q)
      assert length(drained) == 2
      assert PendingMessageQueue.empty?(q)
    end

    test "drain on empty queue yields []" do
      q = PendingMessageQueue.new()
      assert {[], ^q} = PendingMessageQueue.drain(q)
    end

    test "clear empties the queue" do
      q = PendingMessageQueue.new()
      {:ok, q} = PendingMessageQueue.enqueue(q, user("a"))
      assert PendingMessageQueue.has_items?(q)
      q = PendingMessageQueue.clear(q)
      refute PendingMessageQueue.has_items?(q)
    end
  end

  describe "Transport behaviour" do
    test "Direct implements OctoPi.Agent.Transport" do
      behaviours = Transport.Direct.module_info(:attributes) |> Keyword.get_values(:behaviour)
      assert [Transport] in behaviours or Transport in List.flatten(behaviours)
    end
  end

  describe "Tool.Handler behaviour" do
    test "EchoTool implements the handler callback" do
      behaviours = EchoTool.module_info(:attributes) |> Keyword.get_values(:behaviour)

      assert [Tool.Handler] in behaviours or
               Tool.Handler in List.flatten(behaviours)
    end

    test "EchoTool.execute returns an :ok Tool.Result" do
      ref = AbortRef.new()
      on_exit(fn -> AbortRef.forget(ref) end)

      assert {:ok, %Tool.Result{content: [%Content.Text{text: "hello"}]}} =
               EchoTool.execute("call_1", %{"text" => "hello"}, ref, & &1)
    end
  end

  describe "AbortRef" do
    setup do
      ref = AbortRef.new()
      on_exit(fn -> AbortRef.forget(ref) end)
      {:ok, ref: ref}
    end

    test "new refs start un-aborted", %{ref: ref} do
      refute AbortRef.aborted?(ref)
    end

    test "abort/1 flips the flag", %{ref: ref} do
      AbortRef.abort(ref)
      assert AbortRef.aborted?(ref)
    end

    test "abort is idempotent", %{ref: ref} do
      AbortRef.abort(ref)
      AbortRef.abort(ref)
      assert AbortRef.aborted?(ref)
    end

    test "forgotten ref reads as not-aborted" do
      ref = AbortRef.new()
      AbortRef.abort(ref)
      AbortRef.forget(ref)
      refute AbortRef.aborted?(ref)
    end
  end

  describe "Session lifecycle" do
    setup do
      {:ok, session} = OctoPi.Agent.start_session(model: fake_model())
      {:ok, session: session}
    end

    test "state/1 returns the current Session.State", %{session: session} do
      state = OctoPi.Agent.state(session)
      assert state.model.id == "claude-haiku-4-5"
      refute state.is_streaming?
      assert state.messages == []
    end

    test "subscribe/3 returns an unsubscribe fn", %{session: session} do
      unsubscribe = OctoPi.Agent.subscribe(session, self(), :async)
      assert is_function(unsubscribe, 0)
      assert :ok = unsubscribe.()
    end

    test "abort on idle is a no-op", %{session: session} do
      OctoPi.Agent.subscribe(session, self(), :async)
      :ok = OctoPi.Agent.abort(session)
      refute_receive {:octo_pi_agent_event, _}, 50
    end

    test "steer/2 enqueues into the steering queue", %{session: session} do
      :ok = OctoPi.Agent.steer(session, "next, do X")
      state = OctoPi.Agent.state(session)
      assert state.steering_queue.count == 1
    end

    test "follow_up/2 enqueues into the follow-up queue", %{session: session} do
      :ok = OctoPi.Agent.follow_up(session, "anything else?")
      state = OctoPi.Agent.state(session)
      assert state.follow_up_queue.count == 1
    end

    test "wait_for_idle/2 returns :ok immediately when session is idle", %{session: session} do
      assert :ok = OctoPi.Agent.wait_for_idle(session, 100)
    end
  end

  defp fake_model do
    %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 6000
    }
  end
end
