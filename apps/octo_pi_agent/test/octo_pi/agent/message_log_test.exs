defmodule OctoPi.Agent.MessageLogTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.MessageLog

  describe "new/1 and to_list/1" do
    test "empty by default" do
      log = MessageLog.new()
      assert MessageLog.to_list(log) == []
      assert MessageLog.count(log) == 0
    end

    test "round-trips an oldest-first list" do
      list = [:a, :b, :c, :d]
      log = MessageLog.new(list)
      assert MessageLog.to_list(log) == list
      assert MessageLog.count(log) == 4
    end

    test "new/0 == new([])" do
      assert MessageLog.to_list(MessageLog.new()) ==
               MessageLog.to_list(MessageLog.new([]))
    end
  end

  describe "push/2" do
    test "appends one to the end and increments count" do
      log = MessageLog.new([:a, :b])
      log = MessageLog.push(log, :c)
      assert MessageLog.to_list(log) == [:a, :b, :c]
      assert MessageLog.count(log) == 3
    end

    test "preserves invariant: to_list(push(log, x)) == to_list(log) ++ [x]" do
      base = MessageLog.new([1, 2, 3])

      for x <- [:foo, "bar", %{a: 1}, [1, 2], 0] do
        assert MessageLog.to_list(MessageLog.push(base, x)) ==
                 MessageLog.to_list(base) ++ [x]
      end
    end

    test "from empty" do
      log = MessageLog.new() |> MessageLog.push(:only)
      assert MessageLog.to_list(log) == [:only]
      assert MessageLog.count(log) == 1
    end
  end

  describe "append_many/2" do
    test "appends an oldest-first list and increments count" do
      log = MessageLog.new([:a, :b])
      log = MessageLog.append_many(log, [:c, :d, :e])
      assert MessageLog.to_list(log) == [:a, :b, :c, :d, :e]
      assert MessageLog.count(log) == 5
    end

    test "preserves invariant: to_list(append_many(log, more)) == to_list(log) ++ more" do
      base = MessageLog.new([:x, :y])

      for more <- [[], [:a], [:a, :b, :c], 1..50 |> Enum.to_list()] do
        assert MessageLog.to_list(MessageLog.append_many(base, more)) ==
                 MessageLog.to_list(base) ++ more
      end
    end

    test "empty list is a no-op" do
      log = MessageLog.new([:a, :b])
      assert MessageLog.append_many(log, []) == log
    end

    test "appending to empty produces the input list" do
      log = MessageLog.new() |> MessageLog.append_many([:a, :b, :c])
      assert MessageLog.to_list(log) == [:a, :b, :c]
      assert MessageLog.count(log) == 3
    end
  end

  describe "count/1 invariant" do
    test "matches length(to_list(_)) after arbitrary push/append_many sequences" do
      ops = [
        {:push, :a},
        {:append_many, [:b, :c]},
        {:push, :d},
        {:append_many, []},
        {:append_many, Enum.to_list(1..10)},
        {:push, :z}
      ]

      log =
        Enum.reduce(ops, MessageLog.new(), fn
          {:push, x}, acc -> MessageLog.push(acc, x)
          {:append_many, xs}, acc -> MessageLog.append_many(acc, xs)
        end)

      assert MessageLog.count(log) == length(MessageLog.to_list(log))
    end

    test "count matches length after each step" do
      Enum.reduce(1..20, MessageLog.new(), fn i, acc ->
        acc = MessageLog.push(acc, i)
        assert MessageLog.count(acc) == length(MessageLog.to_list(acc))
        acc
      end)
    end
  end

  describe "drop_oldest/2" do
    test "k == 0 is a no-op" do
      log = MessageLog.new([:a, :b, :c])
      assert MessageLog.drop_oldest(log, 0) == log
    end

    test "k < count drops the correct elements" do
      log = MessageLog.new([:a, :b, :c, :d, :e])
      log = MessageLog.drop_oldest(log, 2)
      assert MessageLog.to_list(log) == [:c, :d, :e]
      assert MessageLog.count(log) == 3
    end

    test "k == count returns an empty log" do
      log = MessageLog.new([:a, :b, :c])
      log = MessageLog.drop_oldest(log, 3)
      assert MessageLog.to_list(log) == []
      assert MessageLog.count(log) == 0
    end

    test "k > count returns an empty log" do
      log = MessageLog.new([:a, :b])
      log = MessageLog.drop_oldest(log, 99)
      assert MessageLog.to_list(log) == []
      assert MessageLog.count(log) == 0
    end

    test "drop on empty log stays empty" do
      log = MessageLog.new()
      assert MessageLog.drop_oldest(log, 0) == log
      assert MessageLog.to_list(MessageLog.drop_oldest(log, 5)) == []
      assert MessageLog.count(MessageLog.drop_oldest(log, 5)) == 0
    end

    test "preserves invariant: to_list(drop_oldest(log, k)) == Enum.drop(to_list(log), k)" do
      base = MessageLog.new(Enum.to_list(1..10))

      for k <- [0, 1, 5, 9, 10, 11, 100] do
        assert MessageLog.to_list(MessageLog.drop_oldest(base, k)) ==
                 Enum.drop(MessageLog.to_list(base), k)
      end
    end
  end

  describe "interleaved operations" do
    test "round-tripping through all ops" do
      log =
        MessageLog.new([:start])
        |> MessageLog.push(:two)
        |> MessageLog.append_many([:three, :four])
        |> MessageLog.drop_oldest(1)
        |> MessageLog.push(:five)

      assert MessageLog.to_list(log) == [:two, :three, :four, :five]
      assert MessageLog.count(log) == 4
    end
  end
end
