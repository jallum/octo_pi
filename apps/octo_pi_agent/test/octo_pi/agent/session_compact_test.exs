defmodule OctoPi.Agent.SessionCompactTest do
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

  defp start_session(opts \\ []) do
    opts = Keyword.merge([model: model(), transport: FakeTransport], opts)
    {:ok, pid} = Agent.start_session(opts)
    pid
  end

  describe "compact/2 — happy path" do
    test "returns :ok immediately, emits CompactionRequested then CompactionEnd" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      summary = %{
        summary: "rolled-up",
        first_kept_entry_id: "e-2",
        tokens_before: 1234,
        details: %{},
        from_extension?: false
      }

      assert :ok = Agent.compact(session, custom_instructions: "summarize")

      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref, opts: opts}},
                     1_000

      assert opts == [custom_instructions: "summarize"]
      assert is_reference(ref)

      assert :ok = Agent.compaction_response(session, ref, {:ok, summary})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:ok, ^summary}}}, 1_000

      refute Agent.state(session).is_streaming?
    end

    test "{:cancel, reason} surfaces via CompactionEnd" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      assert :ok = Agent.compaction_response(session, ref, {:cancel, "user said no"})

      assert_receive {:octo_pi_agent_event,
                      %Event.CompactionEnd{result: {:cancel, "user said no"}}},
                     1_000

      refute Agent.state(session).is_streaming?
    end

    test "{:error, reason} surfaces via CompactionEnd" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      assert :ok = Agent.compaction_response(session, ref, {:error, :no_model})

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{result: {:error, :no_model}}},
                     1_000
    end

    test "wait_for_idle/2 unblocks after CompactionEnd" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000
      Agent.compaction_response(session, ref, {:ok, %{summary: "x"}})

      assert :ok = Agent.wait_for_idle(session, 1_000)
    end
  end

  describe "compact/2 — busy paths" do
    test "{:error, :busy} when a stream is in flight" do
      final = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [%Text{text: "ok"}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      sleeping_stream = [
        %AIEvent.Start{partial: %{final | content: [], stop_reason: nil}},
        %AIEvent.Done{reason: :stop, message: final}
      ]

      FakeTransport.set_script([sleeping_stream])

      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.prompt(session, "hi")
      assert {:error, :busy} = Agent.compact(session)

      :ok = Agent.wait_for_idle(session, 2_000)
    end

    test "{:error, :busy} when a previous compact is still in flight" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000

      assert {:error, :busy} = Agent.compact(session)

      Agent.compaction_response(session, ref, {:ok, %{summary: "x"}})
      :ok = Agent.wait_for_idle(session, 1_000)
    end
  end

  describe "compaction_response/3 — staleness" do
    test "{:error, :stale} when ref doesn't match the active turn" do
      session = start_session()

      assert {:error, :stale} =
               Agent.compaction_response(session, make_ref(), {:ok, %{summary: "x"}})
    end

    test "{:error, :stale} when ref is from a superseded compact" do
      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: first_ref}}, 1_000

      :ok = Agent.compaction_response(session, first_ref, {:ok, %{summary: "first"}})
      :ok = Agent.wait_for_idle(session, 1_000)

      assert {:error, :stale} =
               Agent.compaction_response(session, first_ref, {:ok, %{summary: "late"}})
    end
  end

  describe "concurrency: prompt/compact interleavings" do
    test "compact after a stream completes runs cleanly" do
      final = %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [%Text{text: "done"}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: %{final | content: [], stop_reason: nil}},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      session = start_session()
      Agent.subscribe(session, self(), :async)

      :ok = Agent.prompt(session, "hi")
      :ok = Agent.wait_for_idle(session, 2_000)

      :ok = Agent.compact(session)
      assert_receive {:octo_pi_agent_event, %Event.CompactionRequested{ref: ref}}, 1_000
      :ok = Agent.compaction_response(session, ref, {:ok, %{summary: "post-stream"}})

      assert_receive {:octo_pi_agent_event,
                      %Event.CompactionEnd{result: {:ok, %{summary: "post-stream"}}}},
                     1_000
    end
  end
end
