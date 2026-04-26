defmodule OctoPi.Coder.Compaction.PreparationTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Compaction.{FileOps, Preparation, Settings}
  alias OctoPi.Coder.Session.Entry

  # ---- entry builders ----------------------------------------------------

  defp user_msg(text, opts), do: msg("user", text, opts)

  defp assistant_msg(text, opts) do
    content = [%{"type" => "text", "text" => text}]
    msg("assistant", content, opts)
  end

  defp assistant_with_tool(name, path, opts) do
    content = [%{"type" => "toolCall", "name" => name, "arguments" => %{"path" => path}}]
    msg("assistant", content, opts)
  end

  defp msg(role, content, opts) do
    base = %{"role" => role, "content" => content}

    base =
      case opts[:usage] do
        nil -> base
        usage -> Map.put(base, "usage", usage)
      end

    %Entry.Message{
      id: opts[:id] || rand_id(),
      parent_id: opts[:parent_id],
      timestamp: "2026-04-26T00:00:00Z",
      message: base
    }
  end

  defp compaction(summary, first_kept_id, opts \\ []) do
    %Entry.Compaction{
      id: opts[:id] || rand_id(),
      timestamp: "2026-04-26T00:00:00Z",
      summary: summary,
      first_kept_entry_id: first_kept_id,
      tokens_before: opts[:tokens_before] || 10_000,
      from_hook: opts[:from_hook],
      details: opts[:details]
    }
  end

  defp settings(opts \\ []) do
    %Settings{
      enabled: true,
      reserve_tokens: opts[:reserve] || 16_384,
      keep_recent_tokens: opts[:keep] || 20_000
    }
  end

  defp rand_id, do: :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)

  defp text_of(messages) do
    Enum.map_join(messages, "\n", fn
      %{"role" => "user", "content" => c} when is_binary(c) -> c

      %{"role" => "assistant", "content" => blocks} when is_list(blocks) ->
        Enum.map_join(blocks, " ", fn
          %{"type" => "text", "text" => t} -> t
          _ -> ""
        end)

      _ -> ""
    end)
  end

  # ---- guard cases -------------------------------------------------------

  describe "prepare/2 — guards" do
    test "returns nil for an empty path" do
      assert Preparation.prepare([], settings()) == nil
    end

    test "returns nil when path ends with a compaction entry" do
      entries = [
        user_msg("u1", id: "u1"),
        assistant_msg("a1", id: "a1"),
        compaction("prior", "u1")
      ]

      assert Preparation.prepare(entries, settings()) == nil
    end
  end

  # ---- no previous compaction --------------------------------------------

  describe "prepare/2 — no previous compaction" do
    test "boundary_start is 0; tokens_before computed from rebuilt context" do
      u1 = user_msg("hello world", id: "u1")
      a1 = assistant_msg("hi back", id: "a1", parent_id: "u1")
      u2 = user_msg(String.duplicate("x", 4000), id: "u2", parent_id: "a1")
      a2 = assistant_msg(String.duplicate("y", 4000), id: "a2", parent_id: "u2")

      prep = Preparation.prepare([u1, a1, u2, a2], settings(keep: 100))

      assert %Preparation{} = prep
      assert prep.previous_summary == nil
      assert prep.tokens_before > 0
      # First kept should be one of the message ids
      assert prep.first_kept_entry_id in ["u1", "u2", "a2"]
    end
  end

  # ---- with previous compaction (upstream parity) ------------------------

  describe "prepare/2 — with previous compaction" do
    test "preserves kept messages across repeated compactions when they still fit" do
      u1 = user_msg("user msg 1 (summarized by compaction1)", id: "u1")
      a1 = assistant_msg("assistant msg 1", id: "a1", parent_id: "u1")
      u2 = user_msg("user msg 2 - kept by compaction1", id: "u2", parent_id: "a1")
      a2 = assistant_msg("assistant msg 2", id: "a2", parent_id: "u2")
      u3 = user_msg("user msg 3 - kept by compaction1", id: "u3", parent_id: "a2")

      a3 =
        assistant_msg("assistant msg 3",
          id: "a3",
          parent_id: "u3",
          usage: %{
            "input" => 5000,
            "output" => 1000,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "totalTokens" => 6000
          }
        )

      c1 = compaction("First summary", "u2", id: "c1", tokens_before: 6000)
      u4 = user_msg("user msg 4 (new after compaction1)", id: "u4", parent_id: "c1")

      a4 =
        assistant_msg("assistant msg 4",
          id: "a4",
          parent_id: "u4",
          usage: %{
            "input" => 8000,
            "output" => 2000,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "totalTokens" => 10_000
          }
        )

      path = [u1, a1, u2, a2, u3, a3, c1, u4, a4]

      prep = Preparation.prepare(path, settings())
      assert %Preparation{} = prep

      assert prep.previous_summary == "First summary"
      # With ample budget the cut snaps back to the prior boundary
      # (firstKeptEntryId of c1 = u2).
      assert prep.first_kept_entry_id == "u2"
      assert text_of(prep.messages_to_summarize) |> String.contains?("First summary") == false
    end

    test "re-summarizes previously kept messages when recent window moves past them" do
      big = fn s, n -> String.duplicate(s <> " ", n) end

      u1 = user_msg(big.("user msg 1 (summarized by compaction1)", 4), id: "u1")
      a1 = assistant_msg(big.("assistant msg 1", 4), id: "a1", parent_id: "u1")
      u2 = user_msg(big.("user msg 2 - kept by compaction1", 12), id: "u2", parent_id: "a1")
      a2 = assistant_msg(big.("assistant msg 2", 12), id: "a2", parent_id: "u2")
      u3 = user_msg(big.("user msg 3 - kept by compaction1", 12), id: "u3", parent_id: "a2")

      a3 =
        assistant_msg(big.("assistant msg 3", 12),
          id: "a3",
          parent_id: "u3",
          usage: %{
            "input" => 5000,
            "output" => 1000,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "totalTokens" => 6000
          }
        )

      c1 = compaction("First summary", "u2", id: "c1")
      u4 = user_msg(big.("user msg 4 (new after compaction1)", 12), id: "u4", parent_id: "c1")

      a4 =
        assistant_msg(big.("assistant msg 4", 12),
          id: "a4",
          parent_id: "u4",
          usage: %{
            "input" => 8000,
            "output" => 2000,
            "cacheRead" => 0,
            "cacheWrite" => 0,
            "totalTokens" => 10_000
          }
        )

      path = [u1, a1, u2, a2, u3, a3, c1, u4, a4]
      prep = Preparation.prepare(path, settings(keep: 100))

      assert %Preparation{} = prep
      assert prep.previous_summary == "First summary"
      summarized = text_of(prep.messages_to_summarize)
      assert String.contains?(summarized, "user msg 2 - kept by compaction1")
      assert String.contains?(summarized, "user msg 3 - kept by compaction1")
      refute String.contains?(summarized, "First summary")
    end
  end

  # ---- file_ops carry-over ----------------------------------------------

  describe "prepare/2 — file_ops carry-over from previous compaction" do
    test "carries readFiles/modifiedFiles when previous compaction was not from_hook" do
      u1 = user_msg("u1", id: "u1")
      a1 = assistant_msg("a1", id: "a1", parent_id: "u1")

      c1 =
        compaction("prior", "u1",
          id: "c1",
          parent_id: "a1",
          details: %{
            "readFiles" => ["lib/old.ex"],
            "modifiedFiles" => ["lib/changed.ex"]
          }
        )

      u2 = user_msg("u2", id: "u2", parent_id: "c1")
      a2 = assistant_with_tool("read", "lib/new.ex", id: "a2", parent_id: "u2")
      u3 = user_msg(String.duplicate("z", 4000), id: "u3", parent_id: "a2")

      prep = Preparation.prepare([u1, a1, c1, u2, a2, u3], settings(keep: 100))

      assert %Preparation{} = prep
      lists = FileOps.compute_lists(prep.file_ops)
      assert "lib/old.ex" in lists.read_files
      assert "lib/changed.ex" in lists.modified_files
    end

    test "skips carry-over when previous compaction is from_hook" do
      u1 = user_msg("u1", id: "u1")
      a1 = assistant_msg("a1", id: "a1", parent_id: "u1")

      c1 =
        compaction("prior", "u1",
          id: "c1",
          parent_id: "a1",
          from_hook: true,
          details: %{
            "readFiles" => ["lib/should_not_carry.ex"],
            "modifiedFiles" => []
          }
        )

      u2 = user_msg(String.duplicate("z", 4000), id: "u2", parent_id: "c1")

      prep = Preparation.prepare([u1, a1, c1, u2], settings(keep: 100))

      assert %Preparation{} = prep
      lists = FileOps.compute_lists(prep.file_ops)
      refute "lib/should_not_carry.ex" in lists.read_files
    end
  end
end
