defmodule OctoPi.Agent.LoopTest do
  use ExUnit.Case, async: false

  # The agent runs each turn inside a Task; transport-level abort/error
  # tests deliberately leave the scripted stream in a state that makes
  # that Task crash (script exhausted / brutal kill). ExUnit prints the
  # Task supervisor's error log by default — capture it.
  @moduletag capture_log: true

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

  # Named handlers — remote captures avoid telemetry's "local function"
  # performance warning.
  def telemetry_forward_tool_start(_event, _measurements, metadata, %{pid: pid}) do
    send(pid, {:tool_started, metadata.tool_call_id})
  end

  def telemetry_forward_turn_start(_event, _measurements, metadata, %{pid: pid}) do
    send(pid, {:turn_started, metadata.turn})
  end

  def telemetry_forward(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  defp attach_tool_start_signal do
    handler_id = "await-tool-start-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      [:octo_pi_agent, :tool, :start],
      &__MODULE__.telemetry_forward_tool_start/4,
      %{pid: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    :ok
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
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "go")
      # Sync on the tool actually starting, then steer while the
      # probe is still inside its 80ms sleep.
      assert_receive {:tool_started, "c1"}, 2_000
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
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "long task")
      # Sync on the tool actually entering its sleep before we abort.
      assert_receive {:tool_started, "long"}, 2_000

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
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "x")
      assert_receive {:tool_started, "c"}, 2_000

      assert :ok = OctoPi.Agent.abort(session)
      assert :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted}}
      refute_received {:octo_pi_agent_event, %Event.AgentEnd{}}
    end
  end

  describe "before_tool_call hook" do
    test ":allow runs the tool normally" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "ran"}}
      tool_turn = assistant([tool_call], :tool_use)
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

      session =
        start_session(
          tools: [ProbeTool.tool()],
          before_tool_call: fn _ctx -> :allow end
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "allow")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %OctoPi.Agent.Tool.Result{
                           content: [%OctoPi.AI.Content.Text{text: "ran"}],
                           is_error?: false
                         }
                       }}
    end

    test "{:block, reason} prevents execution and yields an error result" do
      tool_call = %ToolCall{
        id: "c",
        name: "probe",
        arguments: %{"label" => "forbidden", "sleep_ms" => 500}
      }

      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%OctoPi.AI.Content.Text{text: "handled"}], :stop)

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

      session =
        start_session(
          tools: [ProbeTool.tool()],
          before_tool_call: fn _ctx -> {:block, "not today"} end
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(session, "deny me")
          :ok = OctoPi.Agent.wait_for_idle(session, 2_000)
        end)

      # Tool would sleep 500ms if allowed — the block prevents it.
      assert elapsed_us < 300_000

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %OctoPi.Agent.Tool.Result{
                           is_error?: true,
                           content: [%OctoPi.AI.Content.Text{text: msg}]
                         }
                       }}

      assert msg =~ "not today"
    end
  end

  describe "after_tool_call hook" do
    test "{:patch, map} merges into the tool result" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "raw"}}
      tool_turn = assistant([tool_call], :tool_use)
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

      patch_fn = fn _ctx ->
        {:patch, %{content: [%OctoPi.AI.Content.Text{text: "patched"}], details: %{tag: :after}}}
      end

      session =
        start_session(
          tools: [ProbeTool.tool()],
          after_tool_call: patch_fn
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "patch me")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %OctoPi.Agent.Tool.Result{
                           content: [%OctoPi.AI.Content.Text{text: "patched"}],
                           details: %{tag: :after}
                         }
                       }}
    end

    test "exception in after hook becomes an error result, loop continues" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "x"}}
      tool_turn = assistant([tool_call], :tool_use)
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

      session =
        start_session(
          tools: [ProbeTool.tool()],
          after_tool_call: fn _ctx -> raise "hook boom" end
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "x")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %OctoPi.Agent.Tool.Result{
                           is_error?: true,
                           content: [%OctoPi.AI.Content.Text{text: msg}]
                         }
                       }}

      assert msg =~ "hook boom"
      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop}}
    end
  end

  describe "telemetry emissions" do
    test "session + turn + tool events fire with expected metadata" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "ok"}}
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

      handler_id = "telemetry-test-#{System.unique_integer([:positive])}"
      test_pid = self()

      events = [
        [:octo_pi_agent, :session, :start],
        [:octo_pi_agent, :session, :stop],
        [:octo_pi_agent, :turn, :start],
        [:octo_pi_agent, :turn, :stop],
        [:octo_pi_agent, :tool, :start],
        [:octo_pi_agent, :tool, :stop]
      ]

      :telemetry.attach_many(
        handler_id,
        events,
        &__MODULE__.telemetry_forward/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      session = start_session(tools: [ProbeTool.tool()])
      :ok = OctoPi.Agent.prompt(session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :session, :start], _, %{model: "fake-model"}}

      assert_received {:telemetry, [:octo_pi_agent, :turn, :start], _, %{turn: 1}}
      assert_received {:telemetry, [:octo_pi_agent, :turn, :stop], %{duration: _}, %{turn: 1}}

      assert_received {:telemetry, [:octo_pi_agent, :tool, :start], _,
                       %{tool_name: "probe", tool_call_id: "c"}}

      assert_received {:telemetry, [:octo_pi_agent, :tool, :stop], %{duration: _},
                       %{is_error?: false}}

      assert_received {:telemetry, [:octo_pi_agent, :turn, :start], _, %{turn: 2}}

      assert_received {:telemetry, [:octo_pi_agent, :session, :stop], %{duration: _},
                       %{reason: :stop}}
    end

    test "tool :error event fires for error results" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"raise" => "boom"}}
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

      handler_id = "telemetry-error-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:octo_pi_agent, :tool, :error],
        &__MODULE__.telemetry_forward/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      session = start_session(tools: [ProbeTool.tool()])
      :ok = OctoPi.Agent.prompt(session, "fail")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :tool, :error], _, %{is_error?: true}}
    end
  end

  describe "hard abort telemetry + synthesized transcript" do
    # Verify the abnormal on_loop_down path fires :session :stop
    # so run-duration meters don't silently drop aborted runs.
    test "hard abort emits [:octo_pi_agent, :session, :stop] with reason :aborted" do
      call = %ToolCall{
        id: "c",
        name: "probe",
        arguments: %{"sleep_ms" => 1_000, "label" => "never"}
      }

      tool_turn = assistant([call], :tool_use)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ]
      ])

      handler_id = "abort-telemetry-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:octo_pi_agent, :session, :stop],
        &__MODULE__.telemetry_forward/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      session = start_session(tools: [ProbeTool.tool()])
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "go")
      assert_receive {:tool_started, "c"}, 2_000
      :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :session, :stop], %{duration: _},
                       %{reason: :aborted}}
    end

    test "synthesized aborted Assistant carries error_message on both paths" do
      # Hard abort path — verified via the AgentEnd messages.
      call = %ToolCall{
        id: "c",
        name: "probe",
        arguments: %{"sleep_ms" => 500, "label" => "x"}
      }

      tool_turn = assistant([call], :tool_use)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "abort soon")
      assert_receive {:tool_started, "c"}, 2_000
      :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted, messages: msgs}}
      synth = List.last(msgs)
      assert %Assistant{stop_reason: :aborted, error_message: "aborted by caller"} = synth
    end
  end

  describe "parallel tool dispatch concurrency cap" do
    test "a large batch runs all tools even when exceeding the cap" do
      calls =
        for i <- 1..20 do
          %ToolCall{
            id: "c#{i}",
            name: "probe",
            arguments: %{"label" => "r#{i}"}
          }
        end

      tool_turn = assistant(calls, :tool_use)
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

      :ok = OctoPi.Agent.prompt(session, "batch of 20")
      :ok = OctoPi.Agent.wait_for_idle(session, 5_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      tool_results = Enum.filter(msgs, &match?(%OctoPi.AI.Message.ToolResult{}, &1))
      assert length(tool_results) == 20
      assert Enum.map(tool_results, & &1.tool_call_id) == Enum.map(1..20, &"c#{&1}")
    end
  end

  describe "defensive: truncated AI stream" do
    test "stream with no Done/Error synthesizes an error assistant" do
      FakeTransport.set_script([
        # No terminal event — just a Start, then the stream ends.
        [%AIEvent.Start{partial: assistant([], nil)}]
      ])

      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "truncated")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :error, messages: msgs}}
      last = List.last(msgs)
      assert %Assistant{stop_reason: :error, error_message: msg} = last
      assert msg =~ "no terminal"
    end
  end

  describe "defensive: double-abort" do
    test "rapid double abort does not crash the session" do
      call = %ToolCall{
        id: "rapid",
        name: "probe",
        arguments: %{"sleep_ms" => 1_000, "label" => "x"}
      }

      tool_turn = assistant([call], :tool_use)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :tool_use, message: tool_turn}
        ]
      ])

      session = start_session(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "x")
      assert_receive {:tool_started, "rapid"}, 2_000

      # Fire two aborts back-to-back without yielding — the second
      # must not blow up on a dead loop pid.
      :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.abort(session)

      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)
      assert Process.alive?(session)
    end
  end

  describe "queue-full at facade" do
    test "steer/2 returns {:error, :full} when the steering queue is at bound" do
      session = start_session(steering_queue_bound: 1)
      assert :ok = OctoPi.Agent.steer(session, "first")
      assert {:error, :full} = OctoPi.Agent.steer(session, "second")
    end

    test "follow_up/2 returns {:error, :full} when the follow-up queue is at bound" do
      session = start_session(follow_up_queue_bound: 1)
      assert :ok = OctoPi.Agent.follow_up(session, "first")
      assert {:error, :full} = OctoPi.Agent.follow_up(session, "second")
    end
  end

  describe "steering queue :all mode" do
    test "set_queue_mode(:steering, :all) drains multiple steers in one pass" do
      tool_call = %ToolCall{
        id: "c1",
        name: "probe",
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
      :ok = OctoPi.Agent.set_queue_mode(session, :steering, :all)
      OctoPi.Agent.subscribe(session, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(session, "go")
      assert_receive {:tool_started, "c1"}, 2_000
      :ok = OctoPi.Agent.steer(session, "note a")
      :ok = OctoPi.Agent.steer(session, "note b")

      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%OctoPi.AI.Message.User{}, &1))
      assert Enum.map(users, & &1.content) == ["go", "note a", "note b"]
    end
  end

  describe "abort during LLM stream" do
    alias OctoPi.Agent.TestSupport.BlockingTransport

    test "brutal-kill unblocks a stuck stream, AgentEnd :aborted fires" do
      handler_id = "turn-start-sync-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:octo_pi_agent, :turn, :start],
        &__MODULE__.telemetry_forward_turn_start/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, session} =
        OctoPi.Agent.start_session(model: model(), transport: BlockingTransport)

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "stuck")
      assert_receive {:turn_started, 1}, 2_000

      :ok = OctoPi.Agent.abort(session)
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted}}
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
