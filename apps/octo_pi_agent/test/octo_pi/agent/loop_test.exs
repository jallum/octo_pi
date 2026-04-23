defmodule OctoPi.Agent.LoopTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.{EchoTool, FakeTransport, ProbeTool}
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.{Model, ToolCall, Usage}

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

  defp start_session(opts \\ []) do
    opts = Keyword.merge([model: model(), transport: FakeTransport], opts)
    {:ok, pid} = OctoPi.Agent.start_session(opts)
    pid
  end

  describe "single-turn text response" do
    test "emits Agent/Turn/Message events in order and exits with :stop" do
      final =
        assistant(
          [%OctoPi.AI.Content.Text{text: "hello"}],
          :stop
        )

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.TextDelta{content_index: 0, delta: "hello", partial: final},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentStart{}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.MessageStart{}}
      assert_received {:octo_pi_agent_event, %Event.MessageUpdate{}}
      assert_received {:octo_pi_agent_event, %Event.MessageEnd{}}
      assert_received {:octo_pi_agent_event, %Event.TurnEnd{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop, messages: msgs}}

      # Transcript: user + assistant.
      assert length(msgs) == 2
    end
  end

  describe "tool_use triggers a second turn" do
    test "dispatches tool, appends tool_result, runs a follow-up turn until :stop" do
      tool_call = %ToolCall{id: "call_1", name: "echo", arguments: %{"text" => "foo"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "done"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [EchoTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "use the echo tool please")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      # Two turns fired, one tool execution, terminal AgentEnd :stop.
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}

      assert_received {:octo_pi_agent_event, %Event.ToolExecutionStart{tool_name: "echo"}}

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         tool_name: "echo",
                         result: %OctoPi.Agent.Tool.Result{
                           content: [%OctoPi.AI.Content.Text{text: "foo"}]
                         }
                       }}

      assert_received {:octo_pi_agent_event, %Event.TurnEnd{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 2}}
      assert_received {:octo_pi_agent_event, %Event.TurnEnd{turn: 2}}

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop, messages: msgs}}

      # user → assistant(tool_use) → tool_result(echo) → assistant(stop)
      assert length(msgs) == 4
    end
  end

  describe "parallel tool dispatch" do
    # Script two parallel tools that each sleep 100ms. Wall-clock
    # for the whole batch should be well under sequential (200ms+).
    test "runs independent tools concurrently" do
      call_a = %ToolCall{id: "a", name: "probe", arguments: %{"sleep_ms" => 100, "label" => "a"}}
      call_b = %ToolCall{id: "b", name: "probe", arguments: %{"sleep_ms" => 100, "label" => "b"}}
      tool_turn = assistant([call_a, call_b], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "done"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(session, "run both")
          :ok = OctoPi.Agent.wait_for_idle(session, 2_000)
        end)

      assert elapsed_us < 180_000,
             "expected parallel execution (< 180ms) got #{div(elapsed_us, 1000)}ms"
    end

    # When any tool in the batch is :sequential, the whole batch
    # runs serially (ape pi-mono L349).
    test "sequential flag on any tool serializes the batch" do
      call_a = %ToolCall{
        id: "a",
        name: "slow_seq",
        arguments: %{"sleep_ms" => 100, "label" => "a"}
      }

      call_b = %ToolCall{
        id: "b",
        name: "slow_seq",
        arguments: %{"sleep_ms" => 100, "label" => "b"}
      }

      tool_turn = assistant([call_a, call_b], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "done"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool("slow_seq", :sequential)])
      OctoPi.Agent.subscribe(session, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(session, "run both serial")
          :ok = OctoPi.Agent.wait_for_idle(session, 2_000)
        end)

      assert elapsed_us >= 195_000,
             "expected sequential (>= 195ms) got #{div(elapsed_us, 1000)}ms"
    end

    test "results appear in source order regardless of completion order" do
      # Slower call is first — if results were ordered by completion
      # the second (fast) one would appear first.
      call_slow = %ToolCall{
        id: "slow",
        name: "probe",
        arguments: %{"sleep_ms" => 120, "label" => "slow"}
      }

      call_fast = %ToolCall{id: "fast", name: "probe", arguments: %{"label" => "fast"}}

      tool_turn = assistant([call_slow, call_fast], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "done"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "order test")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      # user → assistant(tool_use) → tool_result(slow) → tool_result(fast) → assistant(stop)
      tool_results = Enum.filter(msgs, &match?(%OctoPi.AI.Message.ToolResult{}, &1))
      assert Enum.map(tool_results, & &1.tool_call_id) == ["slow", "fast"]
    end

    test "tool_execution_update events fire for streaming tools" do
      call = %ToolCall{
        id: "u1",
        name: "probe",
        arguments: %{"updates" => ["one", "two"], "label" => "done"}
      }

      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "ok"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "stream")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionUpdate{
                         tool_call_id: "u1",
                         partial: %OctoPi.Agent.Tool.Result{
                           content: [%OctoPi.AI.Content.Text{text: "one"}]
                         }
                       }}

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionUpdate{
                         tool_call_id: "u1",
                         partial: %OctoPi.Agent.Tool.Result{
                           content: [%OctoPi.AI.Content.Text{text: "two"}]
                         }
                       }}
    end

    test "a raising tool yields an error tool-result, loop continues" do
      call = %ToolCall{id: "boom", name: "probe", arguments: %{"raise" => "kaboom"}}
      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "recovered"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "break please")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         tool_call_id: "boom",
                         result: %OctoPi.Agent.Tool.Result{
                           is_error?: true,
                           content: [%OctoPi.AI.Content.Text{text: msg}]
                         }
                       }}

      assert msg =~ "kaboom"
      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop}}
    end
  end

  describe "steering queue drainage" do
    # Steer a message while a tool is executing. The message should
    # be injected into the transcript before the follow-up LLM call
    # of the same run. We verify indirectly by checking messages in
    # AgentEnd: user → assistant(tool_use) → tool_result → steered
    # user → assistant(stop).
    test "steered messages land in the transcript for the next turn" do
      tool_call = %ToolCall{
        id: "c1",
        name: "probe",
        # sleep gives the test time to steer during tool exec
        arguments: %{"sleep_ms" => 80, "label" => "ok"}
      }

      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "done"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "go")
      # Steer while the probe tool is sleeping.
      Process.sleep(20)
      :ok = OctoPi.Agent.steer(session, "midway note")

      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      users = Enum.filter(msgs, &match?(%OctoPi.AI.Message.User{}, &1))
      assert Enum.map(users, & &1.content) == ["go", "midway note"]
    end
  end

  describe "follow-up queue drainage" do
    test "follow_up during a run injects after terminal stop and re-loops" do
      first = assistant([%OctoPi.AI.Content.Text{text: "first"}], :stop)
      second = assistant([%OctoPi.AI.Content.Text{text: "second"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: first}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: second}
        ]
      ])

      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "hi")
      # Queue follow-up before the first turn reaches terminal.
      :ok = OctoPi.Agent.follow_up(session, "and then?")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 2}}

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%OctoPi.AI.Message.User{}, &1))
      assert Enum.map(users, & &1.content) == ["hi", "and then?"]
    end

    test "follow_up during idle does not start a run; next prompt drains" do
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.follow_up(session, "carried over")
      refute_receive {:octo_pi_agent_event, _}, 50

      only = assistant([%OctoPi.AI.Content.Text{text: "ok"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: only}
        ]
      ])

      # Next prompt drains the idle-queued follow-up at terminal exit
      # and re-enters the loop.
      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: only}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: only}
        ]
      ])

      :ok = OctoPi.Agent.prompt(session, "now")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%OctoPi.AI.Message.User{}, &1))
      assert Enum.map(users, & &1.content) == ["now", "carried over"]
    end

    test "set_queue_mode(:all) drains multiple follow_ups in one pass" do
      first = assistant([%OctoPi.AI.Content.Text{text: "first"}], :stop)
      second = assistant([%OctoPi.AI.Content.Text{text: "second"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: first}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: second}
        ]
      ])

      session = start_session()
      :ok = OctoPi.Agent.set_queue_mode(session, :follow_up, :all)
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "hi")
      :ok = OctoPi.Agent.follow_up(session, "a")
      :ok = OctoPi.Agent.follow_up(session, "b")

      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      # Only two turns should have run (initial + one combined
      # follow-up turn) because :all drained both in one pass.
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 2}}
      refute_received {:octo_pi_agent_event, %Event.TurnStart{turn: 3}}

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%OctoPi.AI.Message.User{}, &1))
      assert Enum.map(users, & &1.content) == ["hi", "a", "b"]
    end
  end

  describe "cancellation" do
    test "abort during tool execution kills the loop and emits AgentEnd :aborted" do
      call = %ToolCall{
        id: "long",
        name: "probe",
        arguments: %{"sleep_ms" => 1_000, "label" => "never returns"}
      }

      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "unreached"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "long task")
      # Give the loop time to reach the tool's Process.sleep.
      Process.sleep(50)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.abort(session)
          :ok = OctoPi.Agent.wait_for_idle(session, 2_000)
        end)

      # Well under the tool's 1s sleep — brutal kill, not cooperative
      # wait.
      assert elapsed_us < 500_000,
             "expected abort to be fast (< 500ms) got #{div(elapsed_us, 1000)}ms"

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted, messages: msgs}}

      # Synthesized assistant with :aborted stop reason.
      assert %OctoPi.AI.Message.Assistant{stop_reason: :aborted} = List.last(msgs)

      # Session should now be idle.
      refute OctoPi.Agent.state(session).is_streaming?
    end

    test "double abort is a no-op (single AgentEnd, returns :ok both times)" do
      call = %ToolCall{
        id: "c",
        name: "probe",
        arguments: %{"sleep_ms" => 500, "label" => "x"}
      }

      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "x"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "x")
      Process.sleep(50)

      assert :ok = OctoPi.Agent.abort(session)
      assert :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted}}
      refute_received {:octo_pi_agent_event, %Event.AgentEnd{}}
    end
  end

  describe "error stop_reason exits the loop" do
    test "assistant with :error stops, AgentEnd carries :error" do
      errored = assistant([], :error)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: errored},
          %AIEvent.Error{reason: :error, message: errored}
        ]
      ])

      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "fail please")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}
    end
  end
end
