defmodule OctoPi.Coder.Compaction.CutPointTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.CutPoint
  alias OctoPi.Coder.Compaction.CutPoint.Result
  alias OctoPi.Coder.Session.Entry

  # ---- entry builders ----------------------------------------------------

  defp user(text, opts \\ []), do: message("user", text, opts)

  defp assistant(text, opts \\ []),
    do: message("assistant", [%{"type" => "text", "text" => text}], opts)

  defp tool_result(text, opts \\ []), do: message("toolResult", text, opts)

  defp message(role, content, opts) do
    %Entry.Message{
      id: opts[:id] || rand_id(),
      parent_id: opts[:parent_id],
      timestamp: "2026-04-26T00:00:00Z",
      message: %{"role" => role, "content" => content}
    }
  end

  defp model_change(provider \\ "anthropic", model \\ "claude") do
    %Entry.ModelChange{
      id: rand_id(),
      timestamp: "2026-04-26T00:00:00Z",
      provider: provider,
      model_id: model
    }
  end

  defp compaction(summary, first_kept_id, opts \\ []) do
    %Entry.Compaction{
      id: opts[:id] || rand_id(),
      parent_id: opts[:parent_id],
      timestamp: "2026-04-26T00:00:00Z",
      summary: summary,
      first_kept_entry_id: first_kept_id,
      tokens_before: 10_000
    }
  end

  defp rand_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  # ---- find_turn_start_index --------------------------------------------

  describe "find_turn_start_index/3" do
    test "returns -1 when no turn-start exists before the index" do
      entries = [assistant("a"), assistant("b")]
      assert CutPoint.find_turn_start_index(entries, 1, 0) == -1
    end

    test "finds preceding user message" do
      entries = [user("hi"), assistant("a1"), assistant("a2")]
      assert CutPoint.find_turn_start_index(entries, 2, 0) == 0
    end

    test "BranchSummary entry counts as a turn start" do
      entries = [
        %Entry.BranchSummary{
          id: rand_id(),
          timestamp: "2026-04-26T00:00:00Z",
          from_id: "x",
          summary: "s"
        },
        assistant("a")
      ]

      assert CutPoint.find_turn_start_index(entries, 1, 0) == 0
    end

    test "respects start_index lower bound" do
      entries = [user("u0"), user("u1"), assistant("a")]
      assert CutPoint.find_turn_start_index(entries, 2, 1) == 1
    end
  end

  # ---- find_cut_point: trivial cases ------------------------------------

  describe "find_cut_point/4 — degenerate ranges" do
    test "no valid cut points (only tool_result) → returns start_index" do
      entries = [tool_result("just a result")]

      assert %Result{first_kept_entry_index: 0, turn_start_index: -1, split_turn?: false} =
               CutPoint.find_cut_point(entries, 0, 1, 1000)
    end

    test "everything fits within budget → keep from start" do
      entries = [
        user("1"),
        assistant("a"),
        user("2"),
        assistant("b")
      ]

      assert %Result{first_kept_entry_index: 0, split_turn?: false} =
               CutPoint.find_cut_point(entries, 0, 4, 50_000)
    end
  end

  # ---- find_cut_point: turn-boundary cut --------------------------------

  describe "find_cut_point/4 — turn-boundary cuts" do
    test "cuts at a user message when the boundary lands on one" do
      # Each "Assistant N" contributes ~3 tokens (11 chars / 4).
      # We craft sizes so the cut snaps to user at index 4.
      entries = [
        user("Turn 0"),
        assistant(String.duplicate("x", 4000)),
        user("Turn 1"),
        assistant(String.duplicate("y", 4000)),
        user("Turn 2"),
        assistant(String.duplicate("z", 4000))
      ]

      # Each big assistant ≈ 1000 tokens (4000 / 4); each "Turn N" ≈ 2 tokens.
      # Budget 1001 crosses just past the newest assistant (1000) and the
      # cut snaps forward to the closest cut at-or-after that index — the
      # user message at index 4.
      result = CutPoint.find_cut_point(entries, 0, 6, 1001)

      assert result.first_kept_entry_index == 4
      cut = Enum.at(entries, 4)
      assert match?(%Entry.Message{message: %{"role" => "user"}}, cut)
      refute result.split_turn?
      assert result.turn_start_index == -1
    end
  end

  # ---- find_cut_point: mid-turn split -----------------------------------

  describe "find_cut_point/4 — mid-turn splits" do
    test "indicates split_turn when cut lands on an assistant" do
      # One large user turn followed by several assistant chunks.
      entries = [
        user("Turn 1"),
        assistant("A1"),
        user("Turn 2"),
        assistant(String.duplicate("a", 4000)),
        assistant(String.duplicate("b", 4000)),
        assistant(String.duplicate("c", 4000))
      ]

      result = CutPoint.find_cut_point(entries, 0, 6, 2000)

      cut = Enum.at(entries, result.first_kept_entry_index)

      case cut do
        %Entry.Message{message: %{"role" => "assistant"}} ->
          assert result.split_turn?
          assert result.turn_start_index == 2

        %Entry.Message{message: %{"role" => "user"}} ->
          refute result.split_turn?
          assert result.turn_start_index == -1
      end
    end
  end

  # ---- find_cut_point: single huge turn ---------------------------------

  describe "find_cut_point/4 — single huge turn" do
    test "single turn that exceeds budget still cuts to a valid point" do
      entries = [
        user("massive turn"),
        assistant(String.duplicate("x", 100_000))
      ]

      result = CutPoint.find_cut_point(entries, 0, 2, 500)

      cut = Enum.at(entries, result.first_kept_entry_index)
      assert match?(%Entry.Message{}, cut)
      role = cut.message["role"]
      assert role in ["user", "assistant"]
    end

    test "no message entries at all → start_index" do
      entries = [model_change(), model_change()]

      assert %Result{first_kept_entry_index: 0, split_turn?: false} =
               CutPoint.find_cut_point(entries, 0, 2, 1000)
    end
  end

  # ---- cut-point eligibility for synthetic-role messages ---------------

  describe "find_cut_point/4 — synthetic-role cut-point eligibility" do
    # Strategy: prepend an ineligible toolResult so the first valid cut point
    # in the list is the synthetic-role entry at index 1. With a generous
    # budget the walk drains to the default (first valid cut), revealing
    # whether the role is actually in the cut_point? allow-list.
    test "bashExecution entry is a valid cut point" do
      bash = message("bashExecution", %{"command" => "ls", "output" => "a"}, [])
      entries = [tool_result("prefix"), bash, assistant("a")]
      result = CutPoint.find_cut_point(entries, 0, 3, 50_000)
      assert result.first_kept_entry_index == 1
      assert match?(%Entry.Message{message: %{"role" => "bashExecution"}}, Enum.at(entries, 1))
    end

    test "branchSummary entry is a valid cut point" do
      branch = message("branchSummary", %{"summary" => "branch summary"}, [])
      entries = [tool_result("prefix"), branch, assistant("a")]
      result = CutPoint.find_cut_point(entries, 0, 3, 50_000)
      assert result.first_kept_entry_index == 1
      assert match?(%Entry.Message{message: %{"role" => "branchSummary"}}, Enum.at(entries, 1))
    end

    test "compactionSummary entry is a valid cut point" do
      compact = message("compactionSummary", %{"summary" => "compaction summary"}, [])
      entries = [tool_result("prefix"), compact, assistant("a")]
      result = CutPoint.find_cut_point(entries, 0, 3, 50_000)
      assert result.first_kept_entry_index == 1
      assert match?(%Entry.Message{message: %{"role" => "compactionSummary"}}, Enum.at(entries, 1))
    end
  end

  # ---- find_cut_point: against existing compaction boundary ------------

  describe "find_cut_point/4 — pre-existing compaction" do
    test "absorbs leading non-message entries up to but not past a compaction" do
      # Layout: [compaction, model_change, user, assistant].
      # With ample budget the walk never crosses keep_recent_tokens
      # so the default cut is the first valid cut point — the user
      # at index 2. Absorb-leading then pulls in the model_change
      # at index 1 but stops at the compaction at index 0 (compaction
      # is a hard left edge).
      entries = [
        compaction("prior summary", "u-id"),
        model_change(),
        user("u", id: "u-id"),
        assistant("a")
      ]

      result = CutPoint.find_cut_point(entries, 0, 4, 50_000)

      assert result.first_kept_entry_index == 1
      assert match?(%Entry.ModelChange{}, Enum.at(entries, 1))
    end

    test "absorbs leading non-message entries when no compaction blocks" do
      # Generous budget so the walk reaches start without exceeding,
      # leaving the default cut at the first valid cut point (the user
      # at index 2). The absorb step then pulls in the two model_change
      # entries that precede it, since no compaction blocks the way.
      entries = [
        model_change(),
        model_change(),
        user("u"),
        assistant("a")
      ]

      result = CutPoint.find_cut_point(entries, 0, 4, 50_000)

      assert result.first_kept_entry_index == 0
    end
  end
end
