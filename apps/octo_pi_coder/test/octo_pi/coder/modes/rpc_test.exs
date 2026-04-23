defmodule OctoPi.Coder.Modes.RpcTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.{Model, Usage}
  alias OctoPi.Coder.Modes.Rpc

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
      OctoPi.Agent.start_session(model: model(), transport: FakeTransport, tools: [])

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
    test "converts an AgentStart event to a JSON-friendly map" do
      json = Rpc.event_to_json(%Event.AgentStart{})
      assert json["type"] == "event"
      assert json["event"] == "agent_start"
    end

    test "converts a TurnStart event with turn metadata" do
      json = Rpc.event_to_json(%Event.TurnStart{turn: 3})
      assert json["event"] == "turn_start"
      assert json["data"]["turn"] == 3
    end

    test "converts a ToolExecutionStart event" do
      json = Rpc.event_to_json(%Event.ToolExecutionStart{tool_call_id: "c", tool_name: "read"})

      assert json["event"] == "tool_execution_start"
      assert json["data"]["tool_name"] == "read"
    end
  end
end
