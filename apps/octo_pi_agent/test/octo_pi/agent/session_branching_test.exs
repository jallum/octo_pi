defmodule OctoPi.Agent.SessionBranchingTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.SessionEntry.BranchSummaryEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
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
      content: [%Text{text: "branch-summary-text"}],
      stop_reason: :stop,
      usage: %Usage{}
    }

    [%AIEvent.Done{reason: :stop, message: msg}]
  end

  defp start_session(opts \\ []) do
    {:ok, pid} = OctoPi.Agent.start_session(Keyword.merge([model: model(), transport: FakeTransport], opts))
    pid
  end

  defp two_entry_session do
    msg1 = %User{content: "first", timestamp: 0}
    msg2 = %User{content: "second", timestamp: 1}
    session = start_session(messages: [msg1, msg2])
    state = OctoPi.Agent.state(session)
    [entry1, entry2] = state.session_manager.entries
    {session, entry1, entry2}
  end

  # ── fork/2 ───────────────────────────────────────────────────────────────────

  describe "fork/2" do
    test "sets leaf_id to the given entry_id" do
      {session, entry1, _entry2} = two_entry_session()

      :ok = OctoPi.Agent.fork(session, entry1.id)

      state = OctoPi.Agent.state(session)
      assert state.session_manager.leaf_id == entry1.id
    end

    test "returns {:error, :not_found} for unknown entry_id" do
      session = start_session()
      assert {:error, :not_found} = OctoPi.Agent.fork(session, "nonexistent")
    end

    test "after fork, SessionManager.append_message branches from fork point" do
      {session, entry1, _entry2} = two_entry_session()

      :ok = OctoPi.Agent.fork(session, entry1.id)

      state = OctoPi.Agent.state(session)
      new_sm = SessionManager.append_message(state.session_manager, %User{content: "branch", timestamp: 2})
      new_entry = Map.get(new_sm.by_id, new_sm.leaf_id)
      assert new_entry.parent_id == entry1.id
    end
  end

  # ── navigate_tree/3 ──────────────────────────────────────────────────────────

  describe "navigate_tree/3" do
    test "without summarize: true, moves leaf_id to target" do
      {session, entry1, _entry2} = two_entry_session()

      :ok = OctoPi.Agent.navigate_tree(session, entry1.id)

      state = OctoPi.Agent.state(session)
      assert state.session_manager.leaf_id == entry1.id
    end

    test "returns {:error, :not_found} for unknown target" do
      session = start_session()
      assert {:error, :not_found} = OctoPi.Agent.navigate_tree(session, "nonexistent")
    end

    test "with summarize: true appends a BranchSummaryEntry" do
      FakeTransport.set_script([summary_turn()])
      {session, entry1, _entry2} = two_entry_session()

      :ok = OctoPi.Agent.navigate_tree(session, entry1.id, summarize: true)

      state = OctoPi.Agent.state(session)
      assert Enum.any?(state.session_manager.entries, &match?(%BranchSummaryEntry{}, &1))
    end
  end

  # ── build_session_context with BranchSummaryEntry ────────────────────────────

  describe "build_session_context with BranchSummaryEntry" do
    test "inserts '[Branch summary: ...]' synthetic User message" do
      sm = SessionManager.new()
      sm = SessionManager.append_message(sm, %User{content: "hello", timestamp: 0})
      sm = SessionManager.append_branch_summary(sm, "the branch summary", "old-leaf")

      ctx = SessionManager.build_session_context(sm)

      assert Enum.any?(ctx.messages, fn
               %User{content: "[Branch summary: the branch summary]"} -> true
               _ -> false
             end)
    end
  end
end
