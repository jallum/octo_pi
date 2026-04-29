defmodule OctoPi.Coder.CompactionThinkingModelTest do
  @moduledoc """
  Live Anthropic compaction test with a thinking-capable model.
  Port of:
    packages/coding-agent/test/compaction-thinking-model.test.ts

  Only the Anthropic-direct block is ported for now; the Antigravity
  block is out-of-scope until that provider lands.

  Opt in with:
    ANTHROPIC_API_KEY=sk-... mix test --only integration \\
      apps/octo_pi_coder/test/octo_pi/coder/compaction_thinking_model_test.exs

  Note: full thinking API support (budget_tokens in the Anthropic request
  body) is deferred per the anthropic/request.ex "Deferred" note. The
  test exercises the compaction pipeline end-to-end; `thinking_level: :high`
  flows into StreamOptions.reasoning but the wire shape is not yet emitted.
  """

  use ExUnit.Case, async: false

  alias OctoPi.AI.Model
  alias OctoPi.Coder
  alias OctoPi.Coder.Compaction.Result
  alias OctoPi.Coder.Loop
  alias OctoPi.Coder.Session.Entry
  alias OctoPi.Coder.SessionManager
  alias OctoPi.Coder.SessionStore
  alias OctoPi.Coder.SettingsManager

  # Evaluated at compile time — skip the entire module when no auth is set.
  # Run with: ANTHROPIC_API_KEY=sk-... mix test --only integration <path>
  @has_anthropic_auth (System.get_env("ANTHROPIC_API_KEY") || "") != "" or
                        (System.get_env("ANTHROPIC_OAUTH_TOKEN") || "") != ""

  @moduletag :integration
  @moduletag timeout: 180_000
  @moduletag if(@has_anthropic_auth, do: [], else: [skip: "no Anthropic auth"])

  setup_all do
    Application.ensure_all_started(:octo_pi_ai_anthropic)
    Application.ensure_all_started(:octo_pi_agent)
    Application.ensure_all_started(:octo_pi_coder)
    Application.delete_env(:octo_pi_ai, :req_overrides)
    :ok
  end

  # ── helpers ───────────────────────────────────────────────────────────────

  defp thinking_model do
    %Model{
      id: "claude-sonnet-4-6",
      name: "Claude Sonnet 4.6",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 16_000,
      reasoning: true
    }
  end

  defp non_thinking_model do
    %Model{
      id: "claude-haiku-4-5",
      name: "Claude Haiku 4.5",
      api: :anthropic_messages,
      provider: :anthropic,
      base_url: "https://api.anthropic.com/v1",
      context_window: 200_000,
      max_tokens: 16_000
    }
  end

  # Use a tiny keep_recent_tokens so even a short conversation triggers a
  # real LLM summarization call (rather than the "No prior history." shortcut).
  defp tight_settings do
    %{"compaction" => %{"reserveTokens" => 16_384, "keepRecentTokens" => 1}}
  end

  defp open_session(ctx, model, settings \\ nil) do
    id = "think-compact-#{ctx.test}-#{System.unique_integer([:positive])}"
    root = Path.join(System.tmp_dir!(), id)
    cwd = System.tmp_dir!()
    {:ok, sm} = SettingsManager.in_memory(settings || tight_settings())

    {:ok, store} = SessionStore.start_link(id: id, cwd: cwd, root: root)
    on_exit(fn -> if Process.alive?(store), do: SessionStore.close(store) end)

    {:ok, agent} =
      OctoPi.Agent.start_loop(
        model: %Model{
          id: "faux-1",
          name: "Faux",
          api: :faux,
          provider: :faux,
          base_url: "https://example.com",
          context_window: 128_000,
          max_tokens: 16_384
        },
        convert_to_llm: &OctoPi.Coder.Session.Messages.to_llm/1
      )

    on_exit(fn -> if Process.alive?(agent), do: GenServer.stop(agent) end)

    {:ok, session} =
      Loop.start_link(
        extensions: [],
        session_manager: %SessionManager{cwd: cwd, session_id: id},
        store_pid: store,
        agent_pid: agent,
        model_provider: fn -> model end,
        settings_manager: sm
      )

    on_exit(fn -> if Process.alive?(session), do: GenServer.stop(session) end)

    session
  end

  defp add_conversation(session) do
    ts = DateTime.to_iso8601(DateTime.utc_now())

    {:ok, _u_id} =
      Coder.add_entry(session, %Entry.Message{
        id: nil,
        timestamp: ts,
        message: %{"role" => "user", "content" => "Write down the first 10 prime numbers."}
      })

    {:ok, a_id} =
      Coder.add_entry(session, %Entry.Message{
        id: nil,
        timestamp: ts,
        message: %{
          "role" => "assistant",
          "content" => "The first 10 prime numbers are: 2, 3, 5, 7, 11, 13, 17, 19, 23, 29.",
          "usage" => %{"input" => 50, "output" => 30, "cacheRead" => 0, "cacheWrite" => 0}
        }
      })

    a_id
  end

  # Persist the compaction result (mirrors finish_compaction/5 in Session).
  defp persist_compaction(session, %Result{} = r, fallback_first_id) do
    ts = DateTime.to_iso8601(DateTime.utc_now())
    first_kept = r.first_kept_entry_id || fallback_first_id

    {:ok, _} =
      Coder.add_entry(session, %Entry.Compaction{
        id: nil,
        timestamp: ts,
        summary: r.summary,
        first_kept_entry_id: first_kept,
        tokens_before: r.tokens_before,
        details: r.details
      })

    :ok
  end

  # ── Anthropic-direct test block ───────────────────────────────────────────

  describe "Compaction with thinking models (Anthropic)" do
    test "compact/2 with thinking_level: :high returns a non-empty summary", ctx do
      session = open_session(ctx, thinking_model())
      _a_id = add_conversation(session)

      assert {:ok, %{result: %Result{} = r}} = Coder.compact(session, thinking_level: :high)
      assert is_binary(r.summary) and r.summary != ""
      assert r.tokens_before > 0
    end

    test "after compaction the built context begins with a CompactionSummaryMessage", ctx do
      session = open_session(ctx, thinking_model())
      a_id = add_conversation(session)

      {:ok, %{result: %Result{} = r}} = Coder.compact(session, thinking_level: :high)
      persist_compaction(session, r, a_id)

      ctx_map = Coder.build_session_context(session)
      [first | _] = ctx_map.messages
      assert Map.get(first, :role) == "compactionSummary"
    end

    test "compact/2 with non-thinking model also succeeds (comparison baseline)", ctx do
      session = open_session(ctx, non_thinking_model())
      _a_id = add_conversation(session)

      assert {:ok, %{result: %Result{} = r}} = Coder.compact(session, thinking_level: :off)
      assert is_binary(r.summary) and r.summary != ""
      assert r.tokens_before > 0
    end
  end
end
