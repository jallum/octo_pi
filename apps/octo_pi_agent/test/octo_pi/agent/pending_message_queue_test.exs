defmodule OctoPi.Agent.PendingMessageQueueTest do
  use ExUnit.Case, async: true

  alias OctoPi.AI.Message.User
  alias OctoPi.Agent.PendingMessageQueue, as: Q

  defp msg(text), do: %User{content: text, timestamp: 0}

  describe "drain/1" do
    test ":one_at_a_time returns the head only" do
      q = Q.new(:one_at_a_time)
      {:ok, q} = Q.enqueue(q, msg("a"))
      {:ok, q} = Q.enqueue(q, msg("b"))
      {:ok, q} = Q.enqueue(q, msg("c"))

      assert {[%User{content: "a"}], q} = Q.drain(q)
      assert q.count == 2
      assert {[%User{content: "b"}], q} = Q.drain(q)
      assert q.count == 1
      assert {[%User{content: "c"}], q} = Q.drain(q)
      assert q.count == 0
      assert {[], _} = Q.drain(q)
    end

    test ":all returns every item and empties the queue" do
      q = Q.new(:all)
      {:ok, q} = Q.enqueue(q, msg("a"))
      {:ok, q} = Q.enqueue(q, msg("b"))
      {:ok, q} = Q.enqueue(q, msg("c"))

      assert {drained, q} = Q.drain(q)
      assert Enum.map(drained, & &1.content) == ["a", "b", "c"]
      assert q.count == 0
      assert {[], _} = Q.drain(q)
    end
  end

  describe "drain_all/1" do
    # drain_all/1 ignores the configured mode — used by inspection /
    # restore-to-editor APIs that need the full queue regardless of
    # how the in-loop drain wants to pace consumption.
    test "returns every item regardless of :one_at_a_time mode" do
      q = Q.new(:one_at_a_time)
      {:ok, q} = Q.enqueue(q, msg("a"))
      {:ok, q} = Q.enqueue(q, msg("b"))
      {:ok, q} = Q.enqueue(q, msg("c"))

      assert {drained, q} = Q.drain_all(q)
      assert Enum.map(drained, & &1.content) == ["a", "b", "c"]
      assert q.count == 0
      assert Q.empty?(q)
    end

    test "returns [] for an empty queue without changing it" do
      q = Q.new(:one_at_a_time)
      assert {[], ^q} = Q.drain_all(q)
    end

    test "preserves FIFO order in :all mode too" do
      q = Q.new(:all)
      {:ok, q} = Q.enqueue(q, msg("first"))
      {:ok, q} = Q.enqueue(q, msg("second"))

      assert {drained, _} = Q.drain_all(q)
      assert Enum.map(drained, & &1.content) == ["first", "second"]
    end
  end

  describe "enqueue/2 bound" do
    test "rejects with {:error, :full} at bound" do
      q = Q.new(:one_at_a_time, 2)
      {:ok, q} = Q.enqueue(q, msg("a"))
      {:ok, q} = Q.enqueue(q, msg("b"))
      assert {:error, :full} = Q.enqueue(q, msg("c"))
    end
  end
end
