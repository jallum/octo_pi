defmodule OctoPi.Agent.LoopBehaviorTest do
  use ExUnit.Case, async: false

  # End-to-end Loop behavior driven through the public Agent
  # facade. Renamed from LoopTest after F2 (.50) folded Loop into
  # Loop as a Turn-FSM-driven executor.
  #
  # Stream and tool-batch run as Tasks under TurnTaskSupervisor;
  # transport-level abort/error tests deliberately leave the scripted
  # stream in a state that makes that Task crash (script exhausted /
  # brutal kill). ExUnit prints the supervisor's error log by default
  # — capture it.
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.EchoTool
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.Agent.TestSupport.ProbeTool
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage

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

  defp start_loop(opts \\ []) do
    opts = Keyword.merge([model: model(), transport: FakeTransport, convert_to_llm: &Function.identity/1], opts)
    {:ok, pid} = OctoPi.Agent.start_loop(opts)
    pid
  end

  # Helper for assertions on user-message content. Post-opi-5ka.1 every
  # %User{} flowing through Agent.prompt / steer / follow_up has list-
  # shape content (a single %Text{} for a string input).
  defp user_text(%User{content: [%Text{text: t}]}), do: t

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
          [%Text{text: "hello"}],
          :stop
        )

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.TextDelta{content_index: 0, delta: "hello", partial: final},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "hi")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentStart{}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.MessageStart{}}
      assert_received {:octo_pi_agent_event, %Event.MessageBlockDelta{kind: :text, delta: "hello"}}
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [EchoTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "use the echo tool please")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      # Two turns fired, one tool execution, terminal AgentEnd :stop.
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}

      assert_received {:octo_pi_agent_event, %Event.ToolExecutionStart{tool_name: "echo"}}

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         tool_name: "echo",
                         result: %Result{
                           content: [%Text{text: "foo"}]
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(loop, "run both")
          :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool("slow_seq", :sequential)])
      OctoPi.Agent.subscribe(loop, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(loop, "run both serial")
          :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "order test")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      # user → assistant(tool_use) → tool_result(slow) → tool_result(fast) → assistant(stop)
      tool_results = Enum.filter(msgs, &match?(%ToolResult{}, &1))
      assert Enum.map(tool_results, & &1.tool_call_id) == ["slow", "fast"]
    end

    test "tool_execution_update events fire for streaming tools" do
      call = %ToolCall{
        id: "u1",
        name: "probe",
        arguments: %{"updates" => ["one", "two"], "label" => "done"}
      }

      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%Text{text: "ok"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "stream")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionUpdate{
                         tool_call_id: "u1",
                         partial: %Result{
                           content: [%Text{text: "one"}]
                         }
                       }}

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionUpdate{
                         tool_call_id: "u1",
                         partial: %Result{
                           content: [%Text{text: "two"}]
                         }
                       }}
    end

    test "a raising tool yields an error tool-result, loop continues" do
      call = %ToolCall{id: "boom", name: "probe", arguments: %{"raise" => "kaboom"}}
      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%Text{text: "recovered"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "break please")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         tool_call_id: "boom",
                         result: %Result{
                           is_error?: true,
                           content: [%Text{text: msg}]
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "go")
      # Sync on the tool actually starting, then steer while the
      # probe is still inside its 80ms sleep.
      assert_receive {:tool_started, "c1"}, 2_000
      :ok = OctoPi.Agent.steer(loop, "midway note")

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["go", "midway note"]
    end

    # Steer a message *before* prompt() is called. Upstream's runLoop
    # drains steering before the very first stream call (agent-loop.ts
    # L165). Octo_pi previously only drained on :tool_use turns, so a
    # pre-prompt steer was stranded across a single-turn run.
    test "steered messages enqueued before prompt land in turn 1's transcript" do
      final = assistant([%Text{text: "ok"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.steer(loop, "steer-pre")
      :ok = OctoPi.Agent.prompt(loop, "go")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["go", "steer-pre"]
    end

    # Steer during a streaming non-tool turn. Upstream's inner-loop
    # tail (agent-loop.ts L208) drains steering after every turn and
    # re-enters the inner loop if any items arrived, regardless of
    # stop_reason. Octo_pi previously only drained on :tool_use, so
    # a steer mid-stream of a :stop turn was stranded.
    test "steered messages during a non-tool streaming turn run as a follow-up turn" do
      first = assistant([%Text{text: "first"}], :stop)
      second = assistant([%Text{text: "second"}], :stop)

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

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      FakeTransport.set_gate()
      :ok = OctoPi.Agent.prompt(loop, "go")
      :ok = OctoPi.Agent.steer(loop, "steer-mid")
      FakeTransport.release_gate()

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["go", "steer-mid"]
    end

    # When BOTH steering and follow-up are queued at a non-tool stop,
    # steering takes precedence: upstream's inner-loop tail drains
    # steering before falling through to the outer follow-up check
    # (agent-loop.ts L208 + L222).
    test "steering takes precedence over follow_up at non-tool stop" do
      first = assistant([%Text{text: "first"}], :stop)
      second = assistant([%Text{text: "second"}], :stop)
      third = assistant([%Text{text: "third"}], :stop)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: first}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: second}
        ],
        [
          %AIEvent.Start{partial: assistant([], nil)},
          %AIEvent.Done{reason: :stop, message: third}
        ]
      ])

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      FakeTransport.set_gate()
      :ok = OctoPi.Agent.prompt(loop, "go")
      :ok = OctoPi.Agent.follow_up(loop, "fup-after")
      :ok = OctoPi.Agent.steer(loop, "steer-first")
      FakeTransport.release_gate()

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}

      users = Enum.filter(msgs, &match?(%User{}, &1))
      # steer drained at end of turn 1 → "steer-first" runs as turn 2;
      # turn 2 is a non-tool stop with empty steering → outer loop
      # picks up follow_up → "fup-after" runs as turn 3.
      assert Enum.map(users, &user_text/1) == ["go", "steer-first", "fup-after"]
    end
  end

  describe "follow-up queue drainage" do
    test "follow_up during a run injects after terminal stop and re-loops" do
      first = assistant([%Text{text: "first"}], :stop)
      second = assistant([%Text{text: "second"}], :stop)

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

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.follow_up(loop, "and then?")
      :ok = OctoPi.Agent.prompt(loop, "hi")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 2}}

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["hi", "and then?"]
    end

    test "follow_up during idle does not start a run; next prompt drains" do
      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.follow_up(loop, "carried over")
      # Enqueue emits a QueueUpdate snapshot (opi-tze.3) but must NOT
      # emit any run-lifecycle event — idle stays idle.
      assert_received {:octo_pi_agent_event, %Event.QueueUpdate{}}
      refute_receive {:octo_pi_agent_event, _}, 50

      only = assistant([%Text{text: "ok"}], :stop)

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

      :ok = OctoPi.Agent.prompt(loop, "now")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["now", "carried over"]
    end

    test "set_queue_mode(:all) drains multiple follow_ups in one pass" do
      first = assistant([%Text{text: "first"}], :stop)
      second = assistant([%Text{text: "second"}], :stop)

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

      loop = start_loop()
      :ok = OctoPi.Agent.set_queue_mode(loop, :follow_up, :all)
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.follow_up(loop, "a")
      :ok = OctoPi.Agent.follow_up(loop, "b")
      :ok = OctoPi.Agent.prompt(loop, "hi")

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      # Only two turns should have run (initial + one combined
      # follow-up turn) because :all drained both in one pass.
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 1}}
      assert_received {:octo_pi_agent_event, %Event.TurnStart{turn: 2}}
      refute_received {:octo_pi_agent_event, %Event.TurnStart{turn: 3}}

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["hi", "a", "b"]
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
      final_turn = assistant([%Text{text: "unreached"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "long task")
      # Sync on the tool actually entering its sleep before we abort.
      assert_receive {:tool_started, "long"}, 2_000

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.abort(loop)
          :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)
        end)

      # Well under the tool's 1s sleep — brutal kill, not cooperative
      # wait.
      assert elapsed_us < 500_000,
             "expected abort to be fast (< 500ms) got #{div(elapsed_us, 1000)}ms"

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted, messages: msgs}}

      # Synthesized assistant with :aborted stop reason.
      assert %Assistant{stop_reason: :aborted} = List.last(msgs)

      # Loop should now be idle.
      refute OctoPi.Agent.state(loop).is_streaming?
    end

    test "double abort is a no-op (single AgentEnd, returns :ok both times)" do
      call = %ToolCall{
        id: "c",
        name: "probe",
        arguments: %{"sleep_ms" => 500, "label" => "x"}
      }

      tool_turn = assistant([call], :tool_use)
      final_turn = assistant([%Text{text: "x"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "x")
      assert_receive {:tool_started, "c"}, 2_000

      assert :ok = OctoPi.Agent.abort(loop)
      assert :ok = OctoPi.Agent.abort(loop)
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted}}
      refute_received {:octo_pi_agent_event, %Event.AgentEnd{}}
    end
  end

  describe "before_tool_call hook" do
    test ":allow runs the tool normally" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "ran"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%Text{text: "ok"}], :stop)

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

      loop =
        start_loop(
          tools: [ProbeTool.tool()],
          before_tool_call: fn _ctx -> :allow end
        )

      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "allow")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %Result{
                           content: [%Text{text: "ran"}],
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
      final_turn = assistant([%Text{text: "handled"}], :stop)

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

      loop =
        start_loop(
          tools: [ProbeTool.tool()],
          before_tool_call: fn _ctx -> {:block, "not today"} end
        )

      OctoPi.Agent.subscribe(loop, self(), :async)

      {elapsed_us, :ok} =
        :timer.tc(fn ->
          :ok = OctoPi.Agent.prompt(loop, "deny me")
          :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)
        end)

      # Tool would sleep 500ms if allowed — the block prevents it.
      assert elapsed_us < 300_000

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %Result{
                           is_error?: true,
                           content: [%Text{text: msg}]
                         }
                       }}

      assert msg =~ "not today"
    end
  end

  describe "after_tool_call hook" do
    test "{:patch, map} merges into the tool result" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "raw"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%Text{text: "ok"}], :stop)

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
        {:patch, %{content: [%Text{text: "patched"}], details: %{tag: :after}}}
      end

      loop =
        start_loop(
          tools: [ProbeTool.tool()],
          after_tool_call: patch_fn
        )

      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "patch me")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %Result{
                           content: [%Text{text: "patched"}],
                           details: %{tag: :after}
                         }
                       }}
    end

    test "exception in after hook becomes an error result, loop continues" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "x"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%Text{text: "recovered"}], :stop)

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

      loop =
        start_loop(
          tools: [ProbeTool.tool()],
          after_tool_call: fn _ctx -> raise "hook boom" end
        )

      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "x")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event,
                       %Event.ToolExecutionEnd{
                         result: %Result{
                           is_error?: true,
                           content: [%Text{text: msg}]
                         }
                       }}

      assert msg =~ "hook boom"
      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop}}
    end
  end

  describe "telemetry emissions" do
    test "loop + turn + tool events fire with expected metadata" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"label" => "ok"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%Text{text: "done"}], :stop)

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
        [:octo_pi_agent, :loop, :start],
        [:octo_pi_agent, :loop, :stop],
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

      loop = start_loop(tools: [ProbeTool.tool()])
      :ok = OctoPi.Agent.prompt(loop, "hi")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :loop, :start], _, %{model: "fake-model"}}

      assert_received {:telemetry, [:octo_pi_agent, :turn, :start], _, %{turn: 1}}
      assert_received {:telemetry, [:octo_pi_agent, :turn, :stop], %{duration: _}, %{turn: 1}}

      assert_received {:telemetry, [:octo_pi_agent, :tool, :start], _, %{tool_name: "probe", tool_call_id: "c"}}

      assert_received {:telemetry, [:octo_pi_agent, :tool, :stop], %{duration: _}, %{is_error?: false}}

      assert_received {:telemetry, [:octo_pi_agent, :turn, :start], _, %{turn: 2}}

      assert_received {:telemetry, [:octo_pi_agent, :loop, :stop], %{duration: _}, %{reason: :stop}}
    end

    test "tool :stop fires with is_error?: true for error results" do
      tool_call = %ToolCall{id: "c", name: "probe", arguments: %{"raise" => "boom"}}
      tool_turn = assistant([tool_call], :tool_use)
      final_turn = assistant([%Text{text: "done"}], :stop)

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
        [:octo_pi_agent, :tool, :stop],
        &__MODULE__.telemetry_forward/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      loop = start_loop(tools: [ProbeTool.tool()])
      :ok = OctoPi.Agent.prompt(loop, "fail")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :tool, :stop], _, %{is_error?: true}}
    end
  end

  describe "hard abort telemetry + synthesized transcript" do
    # Verify the abnormal on_loop_down path fires :loop :stop
    # so run-duration meters don't silently drop aborted runs.
    test "hard abort emits [:octo_pi_agent, :loop, :stop] with reason :aborted" do
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
        [:octo_pi_agent, :loop, :stop],
        &__MODULE__.telemetry_forward/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      loop = start_loop(tools: [ProbeTool.tool()])
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "go")
      assert_receive {:tool_started, "c"}, 2_000
      :ok = OctoPi.Agent.abort(loop)
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:telemetry, [:octo_pi_agent, :loop, :stop], %{duration: _}, %{reason: :aborted}}
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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "abort soon")
      assert_receive {:tool_started, "c"}, 2_000
      :ok = OctoPi.Agent.abort(loop)
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "batch of 20")
      :ok = OctoPi.Agent.wait_for_idle(loop, 5_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      tool_results = Enum.filter(msgs, &match?(%ToolResult{}, &1))
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

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "truncated")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :error, messages: msgs}}
      last = List.last(msgs)
      assert %Assistant{stop_reason: :error, error_message: msg} = last
      assert msg =~ "no terminal"
    end
  end

  describe "defensive: double-abort" do
    test "rapid double abort does not crash the loop" do
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

      loop = start_loop(tools: [ProbeTool.tool()])
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "x")
      assert_receive {:tool_started, "rapid"}, 2_000

      # Fire two aborts back-to-back without yielding — the second
      # must not blow up on a dead loop pid.
      :ok = OctoPi.Agent.abort(loop)
      :ok = OctoPi.Agent.abort(loop)

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)
      assert Process.alive?(loop)
    end
  end

  describe "queue-full at facade" do
    test "steer/2 returns {:error, :full} when the steering queue is at bound" do
      loop = start_loop(steering_queue_bound: 1)
      assert :ok = OctoPi.Agent.steer(loop, "first")
      assert {:error, :full} = OctoPi.Agent.steer(loop, "second")
    end

    test "follow_up/2 returns {:error, :full} when the follow-up queue is at bound" do
      loop = start_loop(follow_up_queue_bound: 1)
      assert :ok = OctoPi.Agent.follow_up(loop, "first")
      assert {:error, :full} = OctoPi.Agent.follow_up(loop, "second")
    end
  end

  # opi-5ka.2: set_messages/2 routes elements through
  # Message.normalize_if_message/1, lifting User/ToolResult string
  # content to list-shape while passing synthetic transcript types
  # (raw JSON maps, compaction-summary structs) through unchanged.
  describe "set_messages/2 normalization" do
    test "lifts %User{} string content to list-shape; passes others through" do
      loop = start_loop()

      synthetic_map = %{"role" => "compactionSummary", "summary" => "earlier", "timestamp" => 0}

      :ok =
        OctoPi.Agent.set_messages(loop, [
          %User{content: "hi", timestamp: 0},
          %User{content: [%Text{text: "already-list"}], timestamp: 0},
          synthetic_map
        ])

      state = OctoPi.Agent.state(loop)

      assert [
               %User{content: [%Text{text: "hi"}]},
               %User{content: [%Text{text: "already-list"}]},
               ^synthetic_map
             ] = state.messages
    end
  end

  # opi-tze.4: Agent.drain_steering / drain_follow_up are inspection /
  # restore-to-editor APIs and must return ALL queued items regardless
  # of the queue's configured drainage mode (which only controls the
  # in-loop per-turn drain).
  describe "public-API drain returns all items" do
    test "drain_steering/1 returns all queued items in default :one_at_a_time mode" do
      loop = start_loop()

      :ok = OctoPi.Agent.steer(loop, "a")
      :ok = OctoPi.Agent.steer(loop, "b")
      :ok = OctoPi.Agent.steer(loop, "c")

      drained = OctoPi.Agent.drain_steering(loop)
      assert Enum.map(drained, &user_text/1) == ["a", "b", "c"]
      assert OctoPi.Agent.drain_steering(loop) == []
    end

    test "drain_follow_up/1 returns all queued items in default :one_at_a_time mode" do
      loop = start_loop()

      :ok = OctoPi.Agent.follow_up(loop, "a")
      :ok = OctoPi.Agent.follow_up(loop, "b")
      :ok = OctoPi.Agent.follow_up(loop, "c")

      drained = OctoPi.Agent.drain_follow_up(loop)
      assert Enum.map(drained, &user_text/1) == ["a", "b", "c"]
      assert OctoPi.Agent.drain_follow_up(loop) == []
    end
  end

  # opi-tze.3: Event.QueueUpdate fires whenever either queue is
  # mutated (enqueue, public-API drain, in-loop drain). The TUI uses
  # this to render the "Steering: … / Follow-up: …" indicator above
  # the editor.
  describe "queue_update events" do
    test "steer/2 emits QueueUpdate carrying the new full snapshot" do
      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.steer(loop, "a")

      assert_received {:octo_pi_agent_event,
                       %Event.QueueUpdate{
                         steering: [%User{content: [%Text{text: "a"}]}],
                         follow_up: []
                       }}

      :ok = OctoPi.Agent.steer(loop, "b")

      assert_received {:octo_pi_agent_event,
                       %Event.QueueUpdate{
                         steering: [
                           %User{content: [%Text{text: "a"}]},
                           %User{content: [%Text{text: "b"}]}
                         ],
                         follow_up: []
                       }}
    end

    test "follow_up/2 emits QueueUpdate carrying the new full snapshot" do
      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.follow_up(loop, "x")

      assert_received {:octo_pi_agent_event,
                       %Event.QueueUpdate{
                         steering: [],
                         follow_up: [%User{content: [%Text{text: "x"}]}]
                       }}
    end

    test "public-API drain emits QueueUpdate when items were drained" do
      loop = start_loop()
      :ok = OctoPi.Agent.steer(loop, "a")
      :ok = OctoPi.Agent.steer(loop, "b")

      # Subscribe AFTER enqueuing so we only see drain events.
      OctoPi.Agent.subscribe(loop, self(), :async)

      _ = OctoPi.Agent.drain_steering(loop)

      assert_received {:octo_pi_agent_event, %Event.QueueUpdate{steering: [], follow_up: []}}
    end

    test "public-API drain on an empty queue does NOT emit QueueUpdate" do
      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      _ = OctoPi.Agent.drain_steering(loop)
      _ = OctoPi.Agent.drain_follow_up(loop)

      refute_receive {:octo_pi_agent_event, %Event.QueueUpdate{}}, 50
    end

    test "in-loop steering drain emits QueueUpdate (parity with upstream queue_update)" do
      first = assistant([%Text{text: "first"}], :stop)
      second = assistant([%Text{text: "second"}], :stop)

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

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      FakeTransport.set_gate()
      :ok = OctoPi.Agent.prompt(loop, "go")
      :ok = OctoPi.Agent.steer(loop, "steer-mid")
      FakeTransport.release_gate()

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      # Enqueue snapshot then in-loop drain snapshot.
      assert_received {:octo_pi_agent_event,
                       %Event.QueueUpdate{
                         steering: [%User{content: [%Text{text: "steer-mid"}]}]
                       }}

      assert_received {:octo_pi_agent_event, %Event.QueueUpdate{steering: [], follow_up: []}}
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
      final_turn = assistant([%Text{text: "done"}], :stop)

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

      loop = start_loop(tools: [ProbeTool.tool()])
      :ok = OctoPi.Agent.set_queue_mode(loop, :steering, :all)
      OctoPi.Agent.subscribe(loop, self(), :async)
      attach_tool_start_signal()

      :ok = OctoPi.Agent.prompt(loop, "go")
      assert_receive {:tool_started, "c1"}, 2_000
      :ok = OctoPi.Agent.steer(loop, "note a")
      :ok = OctoPi.Agent.steer(loop, "note b")

      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{messages: msgs}}
      users = Enum.filter(msgs, &match?(%User{}, &1))
      assert Enum.map(users, &user_text/1) == ["go", "note a", "note b"]
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

      {:ok, loop} =
        OctoPi.Agent.start_loop(model: model(), transport: BlockingTransport, convert_to_llm: &Function.identity/1)

      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "stuck")
      assert_receive {:turn_started, 1}, 2_000

      :ok = OctoPi.Agent.abort(loop)
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :aborted}}
    end
  end

  describe "error stop_reason exits the loop" do
    test "set_thinking_level/2 changes loop thinking_level (opi-0g4.11)" do
      loop = start_loop()
      assert OctoPi.Agent.state(loop).thinking_level == :off
      :ok = OctoPi.Agent.set_thinking_level(loop, :medium)
      assert OctoPi.Agent.state(loop).thinking_level == :medium
    end

    test "set_model/2 changes loop model (opi-0g4.12)" do
      loop = start_loop()
      original_id = OctoPi.Agent.state(loop).model.id

      new_model = %Model{
        id: "new-model",
        name: "New",
        api: :fake_api,
        provider: :fake,
        base_url: "http://fake",
        context_window: 100,
        max_tokens: 100
      }

      :ok = OctoPi.Agent.set_model(loop, new_model)
      assert OctoPi.Agent.state(loop).model.id == "new-model"
      assert OctoPi.Agent.state(loop).model.id != original_id
    end

    test "assistant with :error stops, AgentEnd carries :error" do
      errored = assistant([], :error)

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: errored},
          %AIEvent.Error{reason: :error, message: errored}
        ]
      ])

      loop = start_loop()
      OctoPi.Agent.subscribe(loop, self(), :async)

      :ok = OctoPi.Agent.prompt(loop, "fail please")
      :ok = OctoPi.Agent.wait_for_idle(loop, 2_000)

      assert_received {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}
    end
  end
end
