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
