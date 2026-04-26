defmodule OctoPi.Agent.CompactionExtensionsTest do
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Extension
  alias OctoPi.Agent.SessionEntry.CompactionEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage

  # ── Extension modules for testing ────────────────────────────────────────────

  defmodule CancelCompactionExtension do
    @moduledoc false
    @behaviour Extension
    @impl true
    def on_event(:session_before_compact, _payload, _ctx), do: {:cancel, :test_cancel}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule CustomCompactionExtension do
    @moduledoc false
    @behaviour Extension
    @impl true
    def on_event(:session_before_compact, _payload, _ctx) do
      {:ok,
       %{
         compaction: %{
           summary: "Extension-provided summary.",
           first_kept_entry_id: "fake-id",
           tokens_before: 42
         }
       }}
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule AfterCompactExtension do
    @moduledoc false
    @behaviour Extension

    def key, do: {__MODULE__, :last_event}

    @impl true
    def on_event(:session_compact, payload, _ctx) do
      :persistent_term.put(key(), payload)
      :ok
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  # ── Setup helpers ─────────────────────────────────────────────────────────────

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
      context_window: nil,
      max_tokens: 100
    }
  end

  defp summary_turn do
    msg = %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: "LLM-generated summary."}],
      stop_reason: :stop,
      usage: %Usage{}
    }

    [%AIEvent.Done{reason: :stop, message: msg}]
  end

  defp start_session(extensions) do
    initial = %User{content: "hello", timestamp: 0}

    {:ok, pid} =
      OctoPi.Agent.start_session(
        model: model(),
        transport: FakeTransport,
        messages: [initial],
        extensions: extensions
      )

    pid
  end

  # ── Tests ─────────────────────────────────────────────────────────────────────

  describe "session_before_compact — cancel" do
    test "hook {:cancel, reason} prevents compaction and emits CompactionEnd{aborted?: true}" do
      session = start_session([CancelCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)

      assert_receive {:octo_pi_agent_event,
                      %Event.CompactionEnd{reason: :manual, aborted?: true, will_retry?: false}},
                     2_000
    end

    test "cancelled compaction does not add a CompactionEntry" do
      session = start_session([CancelCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: true}}, 2_000

      state = OctoPi.Agent.state(session)

      has_compaction =
        Enum.any?(state.session_manager.entries, fn
          %CompactionEntry{} -> true
          _ -> false
        end)

      refute has_compaction
    end

    test "cancelled compaction does not call the transport" do
      # Script empty — any transport call would raise "script exhausted"
      session = start_session([CancelCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: true}}, 2_000
    end
  end

  describe "session_before_compact — custom compaction" do
    test "hook {:ok, %{compaction: custom}} skips LLM call" do
      # Script empty — LLM should not be called
      session = start_session([CustomCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)

      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000
    end

    test "hook-provided summary is in the CompactionEntry" do
      session = start_session([CustomCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000

      state = OctoPi.Agent.state(session)

      compaction_entry =
        Enum.find(state.session_manager.entries, fn
          %CompactionEntry{} -> true
          _ -> false
        end)

      assert compaction_entry.summary == "Extension-provided summary."
    end

    test "hook-provided compaction sets from_hook?: true on CompactionEntry" do
      session = start_session([CustomCompactionExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000

      state = OctoPi.Agent.state(session)

      compaction_entry =
        Enum.find(state.session_manager.entries, fn
          %CompactionEntry{} -> true
          _ -> false
        end)

      assert compaction_entry.from_hook? == true
    end
  end

  describe "session_compact — post-compaction hook" do
    test "session_compact fires after successful LLM compaction" do
      :persistent_term.put(AfterCompactExtension.key(), nil)
      FakeTransport.set_script([summary_turn()])
      session = start_session([AfterCompactExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000

      payload = :persistent_term.get(AfterCompactExtension.key())
      assert payload != nil
      assert %CompactionEntry{} = payload.compaction_entry
      assert payload.from_extension == false
    end

    test "session_compact fires after extension-provided compaction with from_extension: true" do
      :persistent_term.put(AfterCompactExtension.key(), nil)
      session = start_session([CustomCompactionExtension, AfterCompactExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000

      payload = :persistent_term.get(AfterCompactExtension.key())
      assert payload != nil
      assert payload.from_extension == true
    end
  end

  describe "no extension_runner" do
    test "compaction works normally when no extensions are registered" do
      FakeTransport.set_script([summary_turn()])

      {:ok, session} =
        OctoPi.Agent.start_session(
          model: model(),
          transport: FakeTransport,
          messages: [%User{content: "hello", timestamp: 0}]
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.compact(session, keep_recent_tokens: 0)
      assert_receive {:octo_pi_agent_event, %Event.CompactionEnd{aborted?: false}}, 2_000

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      assert Enum.any?(ctx.messages, fn msg ->
               content = Map.get(msg, :content, "")
               is_binary(content) and String.contains?(content, "LLM-generated summary.")
             end)
    end
  end
end
