defmodule OctoPi.Agent.TurnTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Turn
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.ToolCall

  defp assistant(stop_reason, content \\ []) do
    %Assistant{
      api: :anthropic_messages,
      provider: :anthropic,
      model: "claude-test",
      timestamp: 0,
      content: content,
      stop_reason: stop_reason
    }
  end

  defp tool_call(id, name) do
    %ToolCall{id: id, name: name, arguments: %{}}
  end

  defp tool_result(id) do
    %ToolResult{
      tool_call_id: id,
      tool_name: "t",
      content: [%Text{text: "ok"}],
      is_error?: false,
      timestamp: 0
    }
  end

  # Fold a list of events through Turn.handle_event/2 and return the
  # final turn plus a flat trace of every action emitted along the way.
  defp run_script(turn, events) do
    Enum.reduce(events, {turn, []}, fn ev, {t, trace} ->
      {t2, actions} = Turn.handle_event(t, ev)
      {t2, trace ++ actions}
    end)
  end

  describe "new/0" do
    test "starts at :idle, turn id 0, no assistant in flight" do
      assert %Turn{state: :idle, id: 0, assistant_in_flight: nil} = Turn.new()
    end
  end

  describe "happy path: prompt → stream_done :stop" do
    test "emits TurnStart + start_stream, then TurnEnd + turn_done" do
      turn = Turn.new()

      {turn, [{:emit_event, %Event.TurnStart{turn: 1}}, :start_stream]} =
        Turn.handle_event(turn, :prompt_received)

      assert turn.state == :awaiting_response
      assert turn.id == 1

      a = assistant(:stop, [%Text{text: "done"}])

      {turn, actions} = Turn.handle_event(turn, {:stream_done, a})

      assert turn.state == :idle
      assert turn.assistant_in_flight == nil

      assert [
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_done, ^a, [], :stop}
             ] = actions
    end

    test ":length stop reason flows through normally" do
      a = assistant(:length)
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {turn, actions} = Turn.handle_event(turn, {:stream_done, a})

      assert turn.state == :idle
      assert {:turn_done, ^a, [], :length} = List.last(actions)
    end
  end

  describe "tool_use loop" do
    test "stream_done :tool_use → start_tool_batch with extracted calls; then turn_done" do
      call = tool_call("c1", "echo")
      a = assistant(:tool_use, [%Text{text: "calling"}, call])

      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {turn, [{:start_tool_batch, [^call]}]} = Turn.handle_event(turn, {:stream_done, a})

      assert turn.state == :executing_tools
      assert turn.assistant_in_flight == a

      result = tool_result("c1")
      {turn, actions} = Turn.handle_event(turn, {:tool_batch_done, [result]})

      assert turn.state == :idle
      assert turn.assistant_in_flight == nil

      assert [
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_done, ^a, [^result], :tool_use}
             ] = actions
    end

    test "non-toolcall content is filtered out of start_tool_batch" do
      call = tool_call("c1", "echo")
      a = assistant(:tool_use, [%Text{text: "preface"}, call, %Text{text: "trailing"}])

      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {_turn, [{:start_tool_batch, calls}]} = Turn.handle_event(turn, {:stream_done, a})

      assert calls == [call]
    end

    test "id increments across consecutive turns" do
      a = assistant(:stop)

      {turn, [_, _, _, {:turn_done, _, _, :stop}]} =
        run_script(Turn.new(), [:prompt_received, {:stream_done, a}])

      assert turn.id == 1

      {turn, _} = run_script(turn, [:prompt_received, {:stream_done, a}])
      assert turn.id == 2
    end
  end

  describe "abort" do
    test "abort while :idle is a no-op" do
      assert {%Turn{state: :idle, id: 0}, []} = Turn.handle_event(Turn.new(), :abort_requested)
    end

    test "abort while :awaiting_response → :cancelling + cancel_active_task" do
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {turn, actions} = Turn.handle_event(turn, :abort_requested)

      assert turn.state == :cancelling
      assert actions == [:cancel_active_task]
    end

    test "abort while :executing_tools → :cancelling + cancel_active_task" do
      a = assistant(:tool_use, [tool_call("c1", "echo")])

      {turn, _} =
        run_script(Turn.new(), [:prompt_received, {:stream_done, a}])

      assert turn.state == :executing_tools

      {turn, actions} = Turn.handle_event(turn, :abort_requested)

      assert turn.state == :cancelling
      assert actions == [:cancel_active_task]
    end

    test "late stream_done in :cancelling produces synth aborted turn_done" do
      {turn, _} =
        run_script(Turn.new(), [:prompt_received, :abort_requested])

      assert turn.state == :cancelling

      {turn, actions} = Turn.handle_event(turn, {:stream_done, assistant(:stop)})

      assert turn.state == :idle
      assert turn.assistant_in_flight == nil

      assert [
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_synth_done, :aborted, "aborted by caller"}
             ] = actions
    end

    test "late tool_batch_done in :cancelling produces synth aborted turn_done" do
      a = assistant(:tool_use, [tool_call("c1", "echo")])

      {turn, _} =
        run_script(Turn.new(), [:prompt_received, {:stream_done, a}, :abort_requested])

      assert turn.state == :cancelling

      {turn, actions} = Turn.handle_event(turn, {:tool_batch_done, [tool_result("c1")]})

      assert turn.state == :idle
      assert {:turn_synth_done, :aborted, "aborted by caller"} = List.last(actions)
    end

    test "late stream_failed in :cancelling produces synth aborted turn_done" do
      {turn, _} =
        run_script(Turn.new(), [:prompt_received, :abort_requested])

      {turn, actions} = Turn.handle_event(turn, {:stream_failed, :boom})

      assert turn.state == :idle
      assert {:turn_synth_done, :aborted, "aborted by caller"} = List.last(actions)
    end

    test "re-abort while :cancelling is a no-op" do
      {turn, _} =
        run_script(Turn.new(), [:prompt_received, :abort_requested])

      assert {turn2, []} = Turn.handle_event(turn, :abort_requested)
      assert turn2.state == :cancelling
    end
  end

  describe "stream failure" do
    test ":stream_failed in :awaiting_response → synth :error turn_done" do
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {turn, actions} = Turn.handle_event(turn, {:stream_failed, :boom})

      assert turn.state == :idle

      assert [
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_synth_done, :error, msg}
             ] = actions

      assert msg =~ "boom"
      assert msg =~ "stream failed"
    end

    test ":stream_done with :error stop reason flows as a normal turn_done" do
      a = %{assistant(:error) | error_message: "provider died"}

      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)
      {turn, actions} = Turn.handle_event(turn, {:stream_done, a})

      assert turn.state == :idle
      assert {:turn_done, ^a, [], :error} = List.last(actions)
    end
  end

  describe "scripted multi-event sequences" do
    test "two consecutive happy turns produce expected action trace" do
      a1 = assistant(:stop, [%Text{text: "one"}])
      a2 = assistant(:stop, [%Text{text: "two"}])

      {turn, trace} =
        run_script(Turn.new(), [
          :prompt_received,
          {:stream_done, a1},
          :prompt_received,
          {:stream_done, a2}
        ])

      assert turn.state == :idle
      assert turn.id == 2

      assert [
               {:emit_event, %Event.TurnStart{turn: 1}},
               :start_stream,
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_done, ^a1, [], :stop},
               {:emit_event, %Event.TurnStart{turn: 2}},
               :start_stream,
               {:emit_event, %Event.TurnEnd{turn: 2}},
               {:turn_done, ^a2, [], :stop}
             ] = trace
    end

    test "tool_use turn followed by terminal turn" do
      call = tool_call("c1", "echo")
      a1 = assistant(:tool_use, [call])
      a2 = assistant(:stop, [%Text{text: "ok"}])
      r = tool_result("c1")

      {turn, trace} =
        run_script(Turn.new(), [
          :prompt_received,
          {:stream_done, a1},
          {:tool_batch_done, [r]},
          :prompt_received,
          {:stream_done, a2}
        ])

      assert turn.state == :idle
      assert turn.id == 2

      assert [
               {:emit_event, %Event.TurnStart{turn: 1}},
               :start_stream,
               {:start_tool_batch, [^call]},
               {:emit_event, %Event.TurnEnd{turn: 1}},
               {:turn_done, ^a1, [^r], :tool_use},
               {:emit_event, %Event.TurnStart{turn: 2}},
               :start_stream,
               {:emit_event, %Event.TurnEnd{turn: 2}},
               {:turn_done, ^a2, [], :stop}
             ] = trace
    end
  end

  describe "compacting (F3)" do
    test ":idle + {:compact_requested, from, opts} → :compacting + {:start_compaction, opts}" do
      from = {self(), make_ref()}
      opts = [custom_instructions: "x"]

      {turn, actions} = Turn.handle_event(Turn.new(), {:compact_requested, from, opts})

      assert turn.state == :compacting
      assert turn.pending_reply_to == from
      assert actions == [{:start_compaction, opts}]
    end

    test ":compacting + {:compaction_response, result} → :idle + {:reply_to, from, result}" do
      from = {self(), make_ref()}

      {turn, _} = Turn.handle_event(Turn.new(), {:compact_requested, from, []})

      result = {:ok, %{summary: "rolled-up", from_extension?: false}}
      {turn, actions} = Turn.handle_event(turn, {:compaction_response, result})

      assert turn.state == :idle
      assert turn.pending_reply_to == nil
      assert actions == [{:reply_to, from, result}]
    end

    test "cancel/error responses thread through verbatim" do
      from = {self(), make_ref()}
      {turn, _} = Turn.handle_event(Turn.new(), {:compact_requested, from, []})

      {_turn, [{:reply_to, ^from, {:cancel, "user said no"}}]} =
        Turn.handle_event(turn, {:compaction_response, {:cancel, "user said no"}})

      {turn2, _} = Turn.handle_event(Turn.new(), {:compact_requested, from, []})

      {_turn, [{:reply_to, ^from, {:error, :no_model}}]} =
        Turn.handle_event(turn2, {:compaction_response, {:error, :no_model}})
    end

    test "abort while :compacting is a no-op (no Task to kill on Agent's side)" do
      from = {self(), make_ref()}
      {turn, _} = Turn.handle_event(Turn.new(), {:compact_requested, from, []})

      assert {turn2, []} = Turn.handle_event(turn, :abort_requested)
      assert turn2.state == :compacting
      assert turn2.pending_reply_to == from
    end

    test "compact_requested while :awaiting_response raises (must be :idle)" do
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)

      assert_raise ArgumentError, fn ->
        Turn.handle_event(turn, {:compact_requested, {self(), make_ref()}, []})
      end
    end

    test "compaction_response while :idle raises" do
      assert_raise ArgumentError, fn ->
        Turn.handle_event(Turn.new(), {:compaction_response, {:ok, %{}}})
      end
    end

    test "id is not bumped by compaction (compaction is not a turn)" do
      from = {self(), make_ref()}

      {turn, _} =
        run_script(Turn.new(), [
          {:compact_requested, from, []},
          {:compaction_response, {:ok, %{}}}
        ])

      assert turn.id == 0
    end
  end

  describe "unexpected event combinations raise" do
    test "stream_done while :idle raises" do
      assert_raise ArgumentError, ~r/unexpected event/, fn ->
        Turn.handle_event(Turn.new(), {:stream_done, assistant(:stop)})
      end
    end

    test "tool_batch_done while :awaiting_response raises" do
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)

      assert_raise ArgumentError, ~r/unexpected event/, fn ->
        Turn.handle_event(turn, {:tool_batch_done, []})
      end
    end

    test "prompt_received while :awaiting_response raises" do
      {turn, _} = Turn.handle_event(Turn.new(), :prompt_received)

      assert_raise ArgumentError, fn ->
        Turn.handle_event(turn, :prompt_received)
      end
    end

    test "stream_failed while :idle raises" do
      assert_raise ArgumentError, fn ->
        Turn.handle_event(Turn.new(), {:stream_failed, :boom})
      end
    end
  end
end
