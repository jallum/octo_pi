defmodule OctoPi.Agent.CompactionTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Compaction
  alias OctoPi.Agent.SessionEntry.MessageEntry
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.Transport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Usage

  # ── Stub transport ───────────────────────────────────────────────────────────

  defmodule StubTransport do
    @moduledoc false
    @behaviour Transport

    @impl true
    def stream(_model, _context, _opts) do
      summary_text = "This is the summary."

      message = %Assistant{
        api: :stub,
        provider: :stub,
        model: "stub",
        timestamp: 0,
        content: [%Text{text: summary_text}],
        stop_reason: :stop,
        usage: %Usage{}
      }

      [%AIEvent.Done{reason: :stop, message: message}]
    end
  end

  defmodule ErrorTransport do
    @moduledoc false
    @behaviour Transport

    @impl true
    def stream(_model, _context, _opts) do
      message = %Assistant{
        api: :stub,
        provider: :stub,
        model: "stub",
        timestamp: 0,
        content: [],
        stop_reason: :error,
        error_message: "transport exploded",
        usage: %Usage{}
      }

      [%AIEvent.Done{reason: :stop, message: message}]
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

  defp model do
    %OctoPi.AI.Model{
      id: "stub",
      name: "Stub",
      api: :stub,
      provider: :stub,
      base_url: "http://stub",
      context_window: 1000,
      max_tokens: 500
    }
  end

  defp user(text), do: %User{content: text, timestamp: 0}

  defp assistant(text) do
    %Assistant{
      api: :stub,
      provider: :stub,
      model: "stub",
      timestamp: 0,
      content: [%Text{text: text}],
      stop_reason: :stop,
      usage: %Usage{}
    }
  end

  defp tool_result(id) do
    %ToolResult{
      tool_call_id: id,
      tool_name: "bash",
      content: [%Text{text: "ok"}],
      is_error?: false,
      timestamp: 0
    }
  end

  defp sm_with_messages(msgs) do
    Enum.reduce(msgs, SessionManager.new(), &SessionManager.append_message(&2, &1))
  end

  # ── find_cut_point/2 ──────────────────────────────────────────────────────────

  describe "find_cut_point/2" do
    test "returns nil when session is empty" do
      assert Compaction.find_cut_point(SessionManager.new(), 1000) == nil
    end

    test "returns nil when session fits within budget" do
      sm = sm_with_messages([user("hi"), assistant("hello")])
      assert Compaction.find_cut_point(sm, 999_999) == nil
    end

    test "returns entry id when budget is exceeded" do
      sm =
        sm_with_messages([
          user("message one"),
          assistant("reply one"),
          user("message two"),
          assistant("reply two")
        ])

      cut = Compaction.find_cut_point(sm, 1)
      assert is_binary(cut)
      assert Map.has_key?(sm.by_id, cut)
    end

    test "never cuts at a ToolResult — walks back to preceding Assistant" do
      sm =
        sm_with_messages([
          user("run a command"),
          assistant("ok"),
          tool_result("tc1"),
          user("done")
        ])

      # Tiny budget forces a cut somewhere
      cut = Compaction.find_cut_point(sm, 1)

      if cut do
        entry = sm.by_id[cut]

        refute match?(%MessageEntry{message: %ToolResult{}}, entry),
               "cut point must not be a ToolResult entry"
      end
    end

    test "with very small budget returns an id for a user or assistant entry" do
      sm =
        sm_with_messages([
          user("alpha"),
          assistant("beta"),
          user("gamma"),
          assistant("delta")
        ])

      cut = Compaction.find_cut_point(sm, 1)
      assert cut

      entry = sm.by_id[cut]

      assert match?(%MessageEntry{message: %User{}}, entry) or
               match?(%MessageEntry{message: %Assistant{}}, entry)
    end
  end

  # ── prepare/2 ─────────────────────────────────────────────────────────────────

  describe "prepare/2" do
    test "returns nil when nothing to compact" do
      sm = sm_with_messages([user("hi"), assistant("hello")])
      assert Compaction.prepare(sm, 999_999) == nil
    end

    test "splits branch at the cut point" do
      sm =
        sm_with_messages([
          user("a"),
          assistant("b"),
          user("c"),
          assistant("d")
        ])

      result = Compaction.prepare(sm, 1)
      assert result
      assert is_list(result.messages_to_summarize)
      assert is_binary(result.first_kept_entry_id)
      assert is_integer(result.tokens_before)
      assert result.tokens_before > 0
    end

    test "messages_to_summarize are all before first_kept_entry_id" do
      sm =
        sm_with_messages([
          user("a"),
          assistant("b"),
          user("c"),
          assistant("d")
        ])

      result = Compaction.prepare(sm, 1)

      if result do
        branch = SessionManager.get_branch(sm)
        {before_cut, at_and_after} = Enum.split_while(branch, &(&1.id != result.first_kept_entry_id))
        assert result.messages_to_summarize == before_cut
        assert at_and_after != []
      end
    end

    test "tokens_before covers the full branch" do
      sm = sm_with_messages([user("hello world"), assistant("response")])
      result = Compaction.prepare(sm, 1)

      if result do
        assert result.tokens_before > 0
      end
    end
  end

  # ── compact/3 ─────────────────────────────────────────────────────────────────

  describe "compact/3" do
    test "returns {:ok, result} with summary from transport" do
      sm =
        sm_with_messages([
          user("message one"),
          assistant("reply one"),
          user("message two"),
          assistant("reply two")
        ])

      assert {:ok, result} = Compaction.compact(sm, StubTransport, model(), keep_recent_tokens: 1)
      assert result.summary == "This is the summary."
      assert is_binary(result.first_kept_entry_id)
      assert is_integer(result.tokens_before)
    end

    test "does not mutate the session_manager" do
      sm =
        sm_with_messages([
          user("a"),
          assistant("b"),
          user("c"),
          assistant("d")
        ])

      original_count = length(sm.entries)
      Compaction.compact(sm, StubTransport, model(), keep_recent_tokens: 1)
      assert length(sm.entries) == original_count
    end

    test "returns {:error, :nothing_to_compact} when session fits in budget" do
      sm = sm_with_messages([user("hi"), assistant("hello")])
      assert {:error, :nothing_to_compact} = Compaction.compact(sm, StubTransport, model(), keep_recent_tokens: 999_999)
    end

    test "returns {:error, reason} when transport reports error" do
      sm =
        sm_with_messages([
          user("a"),
          assistant("b"),
          user("c"),
          assistant("d")
        ])

      assert {:error, _reason} = Compaction.compact(sm, ErrorTransport, model(), keep_recent_tokens: 1)
    end
  end
end
