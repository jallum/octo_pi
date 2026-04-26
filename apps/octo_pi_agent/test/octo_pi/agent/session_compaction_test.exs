defmodule OctoPi.Agent.SessionCompactionTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage

  @moduletag capture_log: true

  # Transport that blocks the stream until the test sends {:stream_result, events}.
  # Stores the controller PID via Application env so it survives across process
  # boundaries without needing a named process.
  defmodule BlockingTransport do
    @moduledoc false
    @behaviour OctoPi.Agent.Transport

    def set_controller(pid), do: Application.put_env(:octo_pi_agent, :__blocking_transport_pid__, pid)

    @impl true
    def stream(_model, _context, _opts) do
      controller = Application.get_env(:octo_pi_agent, :__blocking_transport_pid__)
      send(controller, :stream_started)

      receive do
        {:stream_result, events} -> events
      end
    end
  end

  setup do
    on_exit(fn ->
      FakeTransport.clear()
      Application.delete_env(:octo_pi_agent, :__blocking_transport_pid__)
    end)

    :ok
  end

  defp model do
    %Model{
      id: "fake-model",
      name: "fake",
      api: :fake_api,
      provider: :fake,
      base_url: "http://fake",
      context_window: nil,
      max_tokens: 100
    }
  end

  defp summary_assistant do
    %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: "This is the summary."}],
      stop_reason: :stop,
      usage: %Usage{}
    }
  end

  defp summary_turn, do: [%AIEvent.Done{reason: :stop, message: summary_assistant()}]

  defp done_turn(text) do
    msg = %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: text}],
      stop_reason: :stop,
      usage: %Usage{}
    }

    [%AIEvent.Done{reason: :stop, message: msg}]
  end

  defp initial_message, do: %User{content: "hello", timestamp: 0}

  defp start_session(opts \\ []) do
    default = [model: model(), transport: FakeTransport, messages: [initial_message()]]
    {:ok, pid} = OctoPi.Agent.start_session(Keyword.merge(default, opts))
    pid
  end

  # ── Streaming guard ──────────────────────────────────────────────────────────

  describe "streaming guard" do
    test "compact returns {:error, :streaming} when a run is in progress" do
      BlockingTransport.set_controller(self())

      session = start_session(transport: BlockingTransport)
      Task.start(fn -> OctoPi.Agent.prompt(session, "go") end)

      # Wait until the loop task is actually blocked inside stream/3.
      assert_receive :stream_started, 2_000

      assert {:error, :streaming} = OctoPi.Agent.compact(session)

      # Unblock the loop so the session can terminate cleanly.
      loop_pid = OctoPi.Agent.state(session).loop_task
      done_msg = summary_assistant()
      send(loop_pid, {:stream_result, [%AIEvent.Done{reason: :stop, message: done_msg}]})
      OctoPi.Agent.wait_for_idle(session, 5_000)
    end
  end

  # ── Happy-path compaction ────────────────────────────────────────────────────

  describe "manual compaction" do
    test "CompactionStart{reason: :manual} fires before the LLM call" do
      FakeTransport.set_script([summary_turn()])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionStart{reason: :manual}}, 2_000
    end

    test "CompactionEnd{reason: :manual} fires after completion" do
      FakeTransport.set_script([summary_turn()])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{reason: :manual, aborted?: false, will_retry?: false}},
                     2_000
    end

    test "CompactionStart comes before CompactionEnd" do
      FakeTransport.set_script([summary_turn()])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)

      assert_receive {:octo_pi_agent_event, %Event.CompactionStart{}}, 2_000
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{}}, 2_000
    end

    test "CompactionEntry is present in session_manager.entries after completion" do
      FakeTransport.set_script([summary_turn()])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{}}, 2_000

      state = OctoPi.Agent.state(session)

      has_compaction =
        Enum.any?(state.session_manager.entries, fn
          %CompactionEntry{} -> true
          _ -> false
        end)

      assert has_compaction
    end

    test "build_session_context includes the compaction summary after compaction" do
      FakeTransport.set_script([summary_turn()])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{}}, 2_000

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      # The context should contain the summary text in at least one message.
      summary_present =
        Enum.any?(ctx.messages, fn msg ->
          content = Map.get(msg, :content, "")
          is_binary(content) and String.contains?(content, "This is the summary.")
        end)

      assert summary_present
    end

    test "session is still usable after compaction" do
      FakeTransport.set_script([summary_turn(), done_turn("great")])
      session = start_session()
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{}}, 2_000

      :ok = OctoPi.Agent.prompt(session, "next question")
      :ok = OctoPi.Agent.wait_for_idle(session, 5_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      assert Enum.any?(ctx.messages, fn
               %Assistant{content: [%Text{text: "great"}]} -> true
               _ -> false
             end)
    end
  end

  # ── Abort during compaction ──────────────────────────────────────────────────

  describe "abort during compaction" do
    test "abort/1 during compaction emits CompactionEnd{aborted?: true}" do
      BlockingTransport.set_controller(self())

      session = start_session(transport: BlockingTransport, messages: [initial_message()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)

      # Wait until the compaction task is blocked inside stream/3.
      assert_receive :stream_started, 2_000

      OctoPi.Agent.abort(session)

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: true}}, 2_000
    end
  end
end
