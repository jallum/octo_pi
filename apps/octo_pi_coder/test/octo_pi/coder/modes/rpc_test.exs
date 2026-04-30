defmodule OctoPi.Coder.Modes.RpcTest do
  use ExUnit.Case, async: false

  # Sessions started here run scripted turns via FakeTransport. When
  # a test ends we stop the session, but a mid-flight turn Task may
  # still race the GenServer's :drain_follow_up call. That crash is
  # expected teardown noise — capture it.
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage
  alias OctoPi.Coder.Modes.Rpc

  @moduletag capture_log: true

  setup do
    on_exit(&FakeTransport.clear/0)
    :ok
  end

  defp model do
    %Model{
      id: "fake-model",
      name: "fake",
      api: :fake_api,
      provider: :fake,
      base_url: "http://fake",
      context_window: 100,
      max_tokens: 100
    }
  end

  defp assistant(content, stop_reason) do
    %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: content,
      stop_reason: stop_reason,
      usage: %Usage{}
    }
  end

  defp open_session do
    {:ok, session} =
      OctoPi.Agent.start_loop(model: model(), transport: FakeTransport, tools: [], convert_to_llm: &Function.identity/1)

    # Stop the session before FakeTransport.clear/0 runs, so lingering
    # Task-supervised turn runs don't race the agent being stopped and
    # crash with "no process" / "script exhausted" error logs.
    ExUnit.Callbacks.on_exit(fn ->
      if Process.alive?(session), do: GenServer.stop(session, :normal, 500)
    end)

    session
  end

  describe "handle_request/2" do
    test "prompt method kicks off a run, returns :ok" do
      final = assistant([%OctoPi.AI.Content.Text{text: "hi"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      session = open_session()

      assert %{"id" => "r1", "result" => "ok"} =
               Rpc.handle_request(session, %{
                 "id" => "r1",
                 "method" => "prompt",
                 "params" => %{"text" => "hello"}
               })
    end

    test "unknown method returns an error response" do
      session = open_session()

      resp =
        Rpc.handle_request(session, %{
          "id" => "r2",
          "method" => "bogus",
          "params" => %{}
        })

      assert resp["id"] == "r2"
      assert resp["error"]["message"] =~ "unknown method"
    end

    test "missing method yields an error" do
      session = open_session()
      resp = Rpc.handle_request(session, %{"id" => "r3"})
      assert resp["error"]["message"] =~ "method"
    end

    test "abort method returns :ok and can be idempotent" do
      session = open_session()

      assert %{"result" => "ok"} =
               Rpc.handle_request(session, %{"id" => "a1", "method" => "abort", "params" => %{}})

      assert %{"result" => "ok"} =
               Rpc.handle_request(session, %{"id" => "a2", "method" => "abort", "params" => %{}})
    end

    test "steer enqueues" do
      session = open_session()

      assert %{"result" => "ok"} =
               Rpc.handle_request(session, %{
                 "id" => "s1",
                 "method" => "steer",
                 "params" => %{"text" => "note"}
               })

      state = OctoPi.Agent.state(session)
      assert state.steering_queue.count == 1
    end
  end

  describe "parse_line/1" do
    test "parses a valid JSON line" do
      assert {:ok, %{"id" => "r1", "method" => "prompt"}} =
               Rpc.parse_line(~s|{"id":"r1","method":"prompt"}|)
    end

    test "returns an error tuple for malformed JSON" do
      assert {:error, _} = Rpc.parse_line("not json")
    end
  end

  describe "event_to_json/1" do
    alias OctoPi.Agent.Tool.Result
    alias OctoPi.AI.Content

    test "AgentStart → empty data" do
      json = Rpc.event_to_json(%Event.AgentStart{})
      assert json["type"] == "event"
      assert json["event"] == "agent_start"
      assert json["data"] == %{}
    end

    test "AgentEnd carries reason, message_count, and final assistant text" do
      user = %OctoPi.AI.Message.User{content: "hi", timestamp: 0}

      final =
        %Assistant{
          api: :fake,
          provider: :fake,
          model: "m",
          timestamp: 0,
          content: [%Content.Text{text: "bye"}],
          stop_reason: :stop
        }

      json =
        Rpc.event_to_json(%Event.AgentEnd{reason: :stop, messages: [user, final]})

      assert json["event"] == "agent_end"
      assert json["data"]["reason"] == "stop"
      assert json["data"]["message_count"] == 2
      assert json["data"]["final_text"] == "bye"
    end

    test "TurnStart + TurnEnd carry turn number" do
      assert %{"event" => "turn_start", "data" => %{"turn" => 3}} =
               Rpc.event_to_json(%Event.TurnStart{turn: 3})

      assert %{"event" => "turn_end", "data" => %{"turn" => 3}} =
               Rpc.event_to_json(%Event.TurnEnd{turn: 3})
    end

    test "MessageUpdate carries current full assistant text" do
      partial = %Assistant{
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0,
        content: [%Content.Text{text: "hello"}]
      }

      json = Rpc.event_to_json(%Event.MessageUpdate{partial: partial})
      assert json["data"]["text"] == "hello"
    end

    test "MessageEnd carries finalized text + stop_reason" do
      msg = %Assistant{
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0,
        content: [%Content.Text{text: "done"}],
        stop_reason: :stop
      }

      json = Rpc.event_to_json(%Event.MessageEnd{message: msg})
      assert json["data"]["text"] == "done"
      assert json["data"]["stop_reason"] == "stop"
    end

    test "ToolExecutionStart carries id + name" do
      json =
        Rpc.event_to_json(%Event.ToolExecutionStart{tool_call_id: "c", tool_name: "read"})

      assert json["data"] == %{"tool_call_id" => "c", "tool_name" => "read"}
    end

    test "ToolExecutionUpdate carries partial result text" do
      partial = %Result{content: [%Content.Text{text: "streaming..."}]}

      json =
        Rpc.event_to_json(%Event.ToolExecutionUpdate{tool_call_id: "c", partial: partial})

      assert json["data"]["text"] == "streaming..."
    end

    test "ToolExecutionEnd carries full result text + is_error" do
      result = %Result{
        content: [%Content.Text{text: "file contents here"}],
        is_error?: false
      }

      json =
        Rpc.event_to_json(%Event.ToolExecutionEnd{
          tool_call_id: "c",
          tool_name: "read",
          result: result
        })

      assert json["data"]["text"] == "file contents here"
      assert json["data"]["is_error"] == false
      assert json["data"]["tool_name"] == "read"
    end
  end
end
