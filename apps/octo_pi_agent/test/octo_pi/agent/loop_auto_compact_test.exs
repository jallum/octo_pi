defmodule OctoPi.Agent.LoopAutoCompactTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent
  alias OctoPi.Agent.Event
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage

  @moduletag capture_log: true

  setup do
    on_exit(&FakeTransport.clear/0)
    :ok
  end

  # context_window: 100, reserve: 60 — input of 70 pushes over (70+60=130>100)
  defp over_model do
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

  defp final_msg(input_tokens) do
    %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: "done"}],
      stop_reason: :stop,
      usage: %Usage{input: input_tokens, output: 5}
    }
  end

  defp turn_events(final) do
    [
      %AIEvent.Start{partial: %{final | content: [], stop_reason: nil}},
      %AIEvent.Done{reason: :stop, message: final}
    ]
  end

  defp start_loop(opts \\ []) do
    opts = Keyword.merge([model: over_model(), transport: FakeTransport, convert_to_llm: &Function.identity/1], opts)
    {:ok, pid} = Agent.start_loop(opts)
    pid
  end

  describe "auto-compact trigger" do
    test "over threshold with follow-up queued: CompactionRequested [auto?: true] then run resumes" do
      first = final_msg(70)
      second = final_msg(0)
      FakeTransport.set_script([turn_events(first), turn_events(second)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      # follow-up in the queue drives the :continue branch in decide_next
      :ok = Agent.follow_up(loop, "after-compact-follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref, opts: opts}},
                     1_000

      assert opts == [auto?: true]

      result = %{summary: "compacted", first_kept_entry_id: "e-1", tokens_before: 1234}
      :ok = Agent.compaction_response(loop, ref, {:ok, result})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^result}}},
                     1_000

      assert :ok = Agent.wait_for_idle(loop, 2_000)

      state = Agent.state(loop)
      refute state.is_streaming?
      refute state.compaction_auto?
    end

    test "below threshold: no compaction, run continues directly" do
      # input 30 + reserve 60 = 90 ≤ 100 — should NOT trigger
      first = final_msg(30)
      second = final_msg(0)
      FakeTransport.set_script([turn_events(first), turn_events(second)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.follow_up(loop, "follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert :ok = Agent.wait_for_idle(loop, 2_000)

      refute_receive {:octo_pi_agent_event, %Event.CompactionRequested{}}, 200
    end

    test "cache_read pushes total over threshold even when input is small" do
      # input 10 + cache_read 80 = 90; 90 + reserve 60 = 150 > ctx 100 → trigger.
      # The bug: prior code looked only at input (10) and let this slip through.
      cached_first = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [%Text{text: "done"}],
        stop_reason: :stop,
        usage: %Usage{input: 10, output: 5, cache_read: 80}
      }

      second = final_msg(0)
      FakeTransport.set_script([turn_events(cached_first), turn_events(second)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.follow_up(loop, "after-compact-follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref, opts: opts}},
                     1_000

      assert opts == [auto?: true]

      result = %{summary: "compacted", first_kept_entry_id: "e-1", tokens_before: 1234}
      :ok = Agent.compaction_response(loop, ref, {:ok, result})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^result}}}, 1_000
      assert :ok = Agent.wait_for_idle(loop, 2_000)
    end

    test "no auto_compact_reserve_tokens: never triggers regardless of usage" do
      # reserve is nil — over_threshold? should return false
      first = final_msg(999_999)
      second = final_msg(0)
      FakeTransport.set_script([turn_events(first), turn_events(second)])

      loop = start_loop()
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.follow_up(loop, "follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert :ok = Agent.wait_for_idle(loop, 2_000)

      refute_receive {:octo_pi_agent_event, %Event.CompactionRequested{}}, 200
    end
  end

  describe "auto-compact failure paths" do
    test "{:error, reason} from compaction_response ends the run" do
      first = final_msg(70)
      FakeTransport.set_script([turn_events(first)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.follow_up(loop, "follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      :ok = Agent.compaction_response(loop, ref, {:error, :no_model})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:error, :no_model}}},
                     1_000

      assert_receive {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}, 1_000

      assert :ok = Agent.wait_for_idle(loop, 1_000)
    end

    test "{:cancel, reason} from compaction_response ends the run" do
      first = final_msg(70)
      FakeTransport.set_script([turn_events(first)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.follow_up(loop, "follow-up")
      :ok = Agent.prompt(loop, "initial")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      :ok = Agent.compaction_response(loop, ref, {:cancel, "user vetoed"})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:cancel, "user vetoed"}}},
                     1_000

      assert_receive {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}, 1_000

      assert :ok = Agent.wait_for_idle(loop, 1_000)
    end
  end

  describe "interaction with manual compact" do
    test "manual compact still uses flip_compaction_idle path (not auto)" do
      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.compact(loop)

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref, opts: opts}},
                     1_000

      # manual compact has no auto?: true in opts
      assert opts == []

      result = %{summary: "manual", first_kept_entry_id: "e-1", tokens_before: 50}
      :ok = Agent.compaction_response(loop, ref, {:ok, result})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^result}}}, 1_000

      assert :ok = Agent.wait_for_idle(loop, 1_000)

      state = Agent.state(loop)
      refute state.is_streaming?
      refute state.compaction_auto?
    end
  end

  # ---------- F5 upstream port: queue resume + smarter trigger ----------

  # Helpers for error / overflow turn scripts.

  defp error_turn(error_message, opts \\ []) do
    ts = Keyword.get(opts, :timestamp, :os.system_time(:millisecond))

    msg = %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: ts,
      content: [],
      stop_reason: :error,
      error_message: error_message,
      usage: %Usage{input: 0, output: 0}
    }

    [%AIEvent.Error{reason: :error, message: msg}]
  end

  # Upstream test 1 — "resume after threshold compaction when only agent-level queued
  # messages exist": already covered by the :continue trigger test above.  The
  # follow-up is queued before the run starts; decide_next drains it; threshold fires;
  # compact succeeds; run resumes.  Nothing new to add here.

  describe "F5: overflow guard (upstream test 2)" do
    test "overflow compact fires once; second overflow emits CompactionEnd error and ends run" do
      # Both overflow error turns carry a timestamp comfortably in the future so
      # they are never treated as stale (> any last_compaction_at_ms we can set).
      future = :os.system_time(:millisecond) + 999_999_999

      FakeTransport.set_script([
        # turn 1: overflow error → triggers compact + retry
        error_turn("prompt is too long: 150 tokens > 100 maximum", timestamp: future),
        # turn 2 (after compact retry): overflow again → no second compact
        error_turn("prompt is too long: 150 tokens > 100 maximum", timestamp: future + 1)
      ])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.prompt(loop, "trigger-overflow")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      result = %{summary: "overflow-compact", first_kept_entry_id: "x", tokens_before: 99}
      :ok = Agent.compaction_response(loop, ref, {:ok, result})

      # First compact ends cleanly...
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^result}}}, 1_000

      # ...then second overflow fires the guard: CompactionEnd error, then AgentEnd
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:error, :overflow_recovery_failed}}},
                     1_000

      assert_receive {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}, 1_000
      assert :ok = Agent.wait_for_idle(loop, 1_000)

      # Guard resets on next run
      state = Agent.state(loop)
      refute state.compaction_overflow_attempted?
    end
  end

  describe "F5: stale pre-compaction usage guard (upstream test 3)" do
    test "pre-compaction successful assistant is ignored when checking error threshold" do
      # Seed the transcript with a high-usage assistant that predates the compaction.
      # timestamp: 0 is far in the past; any compaction will set last_compaction_at_ms
      # to a current epoch value, making this stale.
      old_success = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [],
        stop_reason: :stop,
        usage: %Usage{input: 95, output: 5}
      }

      # model: context_window 100, reserve 60 → old_success.input 95 + 60 = 155 > 100
      # would trigger IF not stale
      loop = start_loop(auto_compact_reserve_tokens: 60, messages: [old_success])
      Agent.subscribe(loop, self(), :async)

      # Manual compact to set last_compaction_at_ms (loop is idle, so this is fine)
      :ok = Agent.compact(loop)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000
      :ok = Agent.compaction_response(loop, ref, {:ok, %{summary: "s", first_kept_entry_id: "e", tokens_before: 0}})
      :ok = Agent.wait_for_idle(loop, 1_000)

      # Now last_compaction_at_ms is set to ~current epoch ms.
      # old_success.timestamp (0) <= last_compaction_at_ms → stale → no trigger.
      FakeTransport.set_script([error_turn("529 overloaded")])

      :ok = Agent.prompt(loop, "post-compaction prompt")
      assert :ok = Agent.wait_for_idle(loop, 2_000)

      # No CompactionRequested should have been emitted for the error turn
      refute_receive {:octo_pi_agent_event, %Event.CompactionRequested{}}, 200
    end
  end

  describe "F5: error message fallback to last successful usage (upstream tests 4 & 5)" do
    test "upstream test 4: error turn triggers compact using prior successful assistant's tokens" do
      # Run 1: successful turn with high input (95 tokens)
      success = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [],
        stop_reason: :stop,
        usage: %Usage{input: 95, output: 5}
      }

      FakeTransport.set_script([
        # run 1: success
        turn_events(success),
        # run 2, turn 1: error with zero input — but prior success has 95 + 60 > 100
        error_turn("529 overloaded")
      ])

      # No compaction between runs → last_compaction_at_ms stays nil → no staleness filter
      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      # Run 1: completes normally (no follow-up so run terminates)
      :ok = Agent.prompt(loop, "first prompt")
      assert :ok = Agent.wait_for_idle(loop, 2_000)

      # Run 2: error turn → over_threshold_on_error? finds success.input=95 → triggers
      :ok = Agent.prompt(loop, "second prompt")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      :ok = Agent.compaction_response(loop, ref, {:ok, %{summary: "s", first_kept_entry_id: "e", tokens_before: 0}})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, _}}}, 1_000
      # :end_after mode → run ends with :error after compact
      assert_receive {:octo_pi_agent_event, %Event.AgentEnd{reason: :error}}, 1_000
      assert :ok = Agent.wait_for_idle(loop, 1_000)
    end

    test "upstream test 5: no prior usage → no threshold compact" do
      FakeTransport.set_script([error_turn("529 overloaded")])

      # Only an error turn — no prior successful assistant in transcript
      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      :ok = Agent.prompt(loop, "prompt")
      assert :ok = Agent.wait_for_idle(loop, 2_000)

      refute_receive {:octo_pi_agent_event, %Event.CompactionRequested{}}, 200
    end
  end

  describe "F5: queue handling during compaction" do
    test "follow_up enqueued during compaction is picked up on resume" do
      first = final_msg(70)
      second = final_msg(0)
      FakeTransport.set_script([turn_events(first), turn_events(second)])

      loop = start_loop(auto_compact_reserve_tokens: 60)
      Agent.subscribe(loop, self(), :async)

      # One follow-up to trigger the :continue path (and thus auto-compact)
      :ok = Agent.follow_up(loop, "initial-follow-up")
      :ok = Agent.prompt(loop, "start")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      # Enqueue another follow-up DURING compaction (before calling compaction_response)
      :ok = Agent.follow_up(loop, "added-during-compact")

      result = %{summary: "mid-compact", first_kept_entry_id: "x", tokens_before: 0}
      :ok = Agent.compaction_response(loop, ref, {:ok, result})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^result}}}, 1_000
      assert :ok = Agent.wait_for_idle(loop, 2_000)

      # Both follow-ups should have reached the transcript (the in-compaction one
      # is drained by drain_queues_into_transcript in after_compaction)
      state = Agent.state(loop)
      messages = state.messages
      # The second turn ran and produced output — transcript has two assistant messages
      assert length(Enum.filter(messages, &match?(%Assistant{}, &1))) == 2
      # follow-up queue should be empty after drain
      assert state.follow_up_queue.items == :queue.new()
    end

    test "prompt during compaction returns {:error, :already_streaming}" do
      first = final_msg(70)
      FakeTransport.set_script([turn_events(first)])

      loop = start_loop(auto_compact_reserve_tokens: 60)

      :ok = Agent.follow_up(loop, "follow-up")
      :ok = Agent.prompt(loop, "start")

      Agent.subscribe(loop, self(), :async)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      # prompt while compacting should be rejected
      assert {:error, :already_streaming} = Agent.prompt(loop, "too-early")

      :ok = Agent.compaction_response(loop, ref, {:ok, %{summary: "s", first_kept_entry_id: "x", tokens_before: 0}})
      assert :ok = Agent.wait_for_idle(loop, 2_000)
    end
  end
end
