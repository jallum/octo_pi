defmodule OctoPi.AgentTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.AbortRef
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Loop
  alias OctoPi.Agent.Message
  alias OctoPi.Agent.PendingMessageQueue
  alias OctoPi.Agent.TestSupport.EchoTool
  alias OctoPi.Agent.Tool
  alias OctoPi.Agent.Transport
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model

  describe "contract structs" do
    test "Message union types include User/Assistant/ToolResult" do
      # All three are reused from octo_pi_ai; see OctoPi.AITest for
      # construction assertions. The union is purely a type, so this
      # test exists to anchor the documentation that the membership is
      # exactly these three.
      assert Message
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
      assert %Event.MessageBlockStart{block_id: 0, kind: :text}
      assert %Event.MessageBlockDelta{block_id: 0, kind: :text, delta: "hi", snapshot: "hi"}
      assert %Event.MessageBlockEnd{block_id: 0, kind: :text, content: "hi"}
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

    test "Loop.State enforces :model, :transport, and :convert_to_llm" do
      state = %Loop.State{
        model: fake_model(),
        transport: Transport.Direct,
        convert_to_llm: &Function.identity/1
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
      behaviours = :attributes |> Transport.Direct.module_info() |> Keyword.get_values(:behaviour)
      assert [Transport] in behaviours or Transport in List.flatten(behaviours)
    end
  end

  describe "Tool.Handler behaviour" do
    test "EchoTool implements the handler callback" do
      behaviours = :attributes |> EchoTool.module_info() |> Keyword.get_values(:behaviour)

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

  describe "Loop lifecycle" do
    setup do
      {:ok, loop} = OctoPi.Agent.start_loop(model: fake_model(), convert_to_llm: &Function.identity/1)
      {:ok, loop: loop}
    end

    test "state/1 returns the current Loop.State", %{loop: loop} do
      state = OctoPi.Agent.state(loop)
      assert state.model.id == "claude-haiku-4-5"
      refute state.is_streaming?
      assert state.messages == []
    end

    test "subscribe/3 returns an unsubscribe fn", %{loop: loop} do
      unsubscribe = OctoPi.Agent.subscribe(loop, self(), :async)
      assert is_function(unsubscribe, 0)
      assert :ok = unsubscribe.()
    end

    test "abort on idle is a no-op", %{loop: loop} do
      OctoPi.Agent.subscribe(loop, self(), :async)
      :ok = OctoPi.Agent.abort(loop)
      refute_receive {:octo_pi_agent_event, _}, 50
    end

    test "steer/2 enqueues into the steering queue", %{loop: loop} do
      :ok = OctoPi.Agent.steer(loop, "next, do X")
      state = OctoPi.Agent.state(loop)
      assert state.steering_queue.count == 1
    end

    test "follow_up/2 enqueues into the follow-up queue", %{loop: loop} do
      :ok = OctoPi.Agent.follow_up(loop, "anything else?")
      state = OctoPi.Agent.state(loop)
      assert state.follow_up_queue.count == 1
    end

    test "wait_for_idle/2 returns :ok immediately when loop is idle", %{loop: loop} do
      assert :ok = OctoPi.Agent.wait_for_idle(loop, 100)
    end

    test "add_tool/2 appends a tool to the loop's tool list", %{loop: loop} do
      tool = %{name: "search", description: "search tool", input_schema: %{}}
      :ok = OctoPi.Agent.add_tool(loop, tool)
      state = OctoPi.Agent.state(loop)
      assert Enum.any?(state.tools, &(&1.name == "search"))
    end

    test "add_tool/2 is a no-op if a tool with the same name already exists", %{loop: loop} do
      tool = %{name: "search", description: "first", input_schema: %{}}
      :ok = OctoPi.Agent.add_tool(loop, tool)
      :ok = OctoPi.Agent.add_tool(loop, %{name: "search", description: "second", input_schema: %{}})
      state = OctoPi.Agent.state(loop)
      tools = Enum.filter(state.tools, &(&1.name == "search"))
      assert length(tools) == 1
      assert hd(tools).description == "first"
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
