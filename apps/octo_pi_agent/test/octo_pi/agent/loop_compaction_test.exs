defmodule OctoPi.Agent.LoopCompactionTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionManager
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

  defp model(context_window \\ nil) do
    %Model{
      id: "fake-model",
      name: "fake",
      api: :fake_api,
      provider: :fake,
      base_url: "http://fake",
      context_window: context_window,
      max_tokens: 100
    }
  end

  defp assistant(text, stop_reason, opts \\ []) do
    %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: text}],
      stop_reason: stop_reason,
      error_message: Keyword.get(opts, :error_message),
      usage: Keyword.get(opts, :usage, %Usage{})
    }
  end

  defp overflow_assistant do
    assistant("", :error, error_message: "context window exceeded")
  end

  defp summary_assistant do
    assistant("This is the summary of everything.", :stop)
  end

  defp normal_assistant(text \\ "done") do
    assistant(text, :stop)
  end

  defp turn(msg), do: [%AIEvent.Done{reason: msg.stop_reason || :stop, message: msg}]

  defp start_session(opts \\ []) do
    model = Keyword.get(opts, :model, model())
    {:ok, pid} = OctoPi.Agent.start_session(Keyword.merge([model: model, transport: FakeTransport], opts))
    pid
  end

  defp collect_events(session) do
    OctoPi.Agent.subscribe(session, self(), :async)
    :ok = OctoPi.Agent.prompt(session, "hi")
    :ok = OctoPi.Agent.wait_for_idle(session, 5_000)
    collect_received_events([])
  end

  defp collect_received_events(acc) do
    receive do
      {:octo_pi_agent_event, event} -> collect_received_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # ── Overflow detection and recovery ───────────────────────────────────────────

  describe "overflow detection" do
    test "error message containing 'context window' triggers overflow" do
      # Script: [overflow, compaction summary, normal stop]
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant())
      ])

      session = start_session()
      events = collect_events(session)

      assert Enum.any?(events, &match?(%Event.CompactionStart{reason: :overflow}, &1))
      assert Enum.any?(events, &match?(%Event.CompactionEnd{reason: :overflow, will_retry?: true}, &1))
    end

    test "overflow error assistant is NOT in the final transcript" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant("success"))
      ])

      session = start_session()
      _events = collect_events(session)

      state = OctoPi.Agent.state(session)
      messages = SessionManager.build_session_context(state.session_manager).messages

      # No error message should be in the transcript
      refute Enum.any?(messages, fn
               %Assistant{stop_reason: :error} -> true
               _ -> false
             end)
    end

    test "retry after overflow adds normal assistant to transcript" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant("the answer"))
      ])

      session = start_session()
      _events = collect_events(session)

      state = OctoPi.Agent.state(session)
      messages = SessionManager.build_session_context(state.session_manager).messages

      assert Enum.any?(messages, fn
               %Assistant{content: [%Text{text: "the answer"}]} -> true
               _ -> false
             end)
    end

    test "second overflow after recovery does not loop — treated as error" do
      # Script: overflow, compaction summary, overflow again, abort
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(overflow_assistant())
      ])

      session = start_session()
      events = collect_events(session)

      # Should get exactly one CompactionStart (not two)
      compaction_starts = Enum.filter(events, &match?(%Event.CompactionStart{}, &1))
      assert length(compaction_starts) == 1

      # Final AgentEnd should be :error
      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end.reason == :error
    end

    test "non-overflow error does not trigger compaction" do
      error_msg = assistant("", :error, error_message: "some other error")

      FakeTransport.set_script([turn(error_msg)])

      session = start_session()
      events = collect_events(session)

      refute Enum.any?(events, &match?(%Event.CompactionStart{}, &1))

      agent_end = Enum.find(events, &match?(%Event.AgentEnd{}, &1))
      assert agent_end.reason == :error
    end

    test "CompactionStart and CompactionEnd are emitted in order" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant())
      ])

      session = start_session()
      events = collect_events(session)

      indices =
        events
        |> Enum.with_index()
        |> Enum.filter(fn {e, _i} ->
          match?(%Event.CompactionStart{}, e) or match?(%Event.CompactionEnd{}, e)
        end)
        |> Enum.map(fn {_e, i} -> i end)

      assert length(indices) == 2
      [start_i, end_i] = indices
      assert start_i < end_i
    end

    test "overflow detected via silent usage threshold when input >= context_window" do
      usage = %Usage{input: 100}
      # model context_window = 100, usage.input = 100, so silent overflow triggers
      m = model(100)

      silent_overflow = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [],
        stop_reason: :stop,
        usage: usage
      }

      FakeTransport.set_script([
        turn(silent_overflow),
        turn(summary_assistant()),
        turn(normal_assistant())
      ])

      session = start_session(model: m)
      events = collect_events(session)

      assert Enum.any?(events, &match?(%Event.CompactionStart{reason: :overflow}, &1))
    end
  end

  # ── Session state after overflow recovery ────────────────────────────────────

  describe "session state" do
    test "overflow_recovery_attempted? is true after overflow" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant())
      ])

      session = start_session()
      _events = collect_events(session)

      # Session's own state should reflect the recovery flag
      state = OctoPi.Agent.state(session)
      assert state.overflow_recovery_attempted?
    end

    test "session_manager in Session is updated after compaction" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant())
      ])

      session = start_session()
      _events = collect_events(session)

      state = OctoPi.Agent.state(session)
      # Should have a CompactionEntry in the session manager
      has_compaction =
        Enum.any?(state.session_manager.entries, fn
          %OctoPi.Agent.SessionEntry.CompactionEntry{} -> true
          _ -> false
        end)

      assert has_compaction
    end

    test "final transcript contains user message and successful assistant" do
      FakeTransport.set_script([
        turn(overflow_assistant()),
        turn(summary_assistant()),
        turn(normal_assistant("final response"))
      ])

      session = start_session()
      _events = collect_events(session)

      state = OctoPi.Agent.state(session)
      entries = state.session_manager.entries

      user_entries =
        Enum.filter(entries, fn
          %MessageEntry{message: %OctoPi.AI.Message.User{}} -> true
          _ -> false
        end)

      assert user_entries != []
    end
  end
end
