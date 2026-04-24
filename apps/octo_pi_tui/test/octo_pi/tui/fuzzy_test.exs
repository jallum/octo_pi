defmodule OctoPi.TUI.FuzzyTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Fuzzy

  describe "match/2" do
    test "empty query matches everything" do
      assert %{matches: true, score: 0.0} = Fuzzy.match("", "anything")
    end

    test "query longer than text never matches" do
      assert %{matches: false} = Fuzzy.match("abcdefg", "abc")
    end

    test "exact match" do
      assert %{matches: true} = Fuzzy.match("hello", "hello")
    end

    test "case insensitive by default" do
      assert %{matches: true} = Fuzzy.match("hello", "HELLO")
      assert %{matches: true} = Fuzzy.match("HELLO", "hello")
    end

    test "subsequence match" do
      assert %{matches: true} = Fuzzy.match("hlo", "hello")
    end

    test "no match when characters not in order" do
      assert %{matches: false} = Fuzzy.match("ba", "abc")
    end

    test "consecutive matches score better than gaps" do
      %{score: consecutive} = Fuzzy.match("ab", "abc")
      %{score: gapped} = Fuzzy.match("ab", "axbxc")
      assert consecutive < gapped
    end

    test "word boundary matches score better" do
      %{score: boundary} = Fuzzy.match("fb", "foo_bar")
      %{score: interior} = Fuzzy.match("fb", "ffbxx")
      assert boundary < interior
    end

    test "swapped alpha-numeric query" do
      assert %{matches: true} = Fuzzy.match("abc123", "123abc")
    end

    test "swapped numeric-alpha query" do
      assert %{matches: true} = Fuzzy.match("123abc", "abc123")
    end

    test "swapped match has penalty over same-text direct" do
      %{score: direct} = Fuzzy.match("123abc", "123abc")
      %{score: swapped} = Fuzzy.match("abc123", "123abc")
      assert swapped > direct
    end
  end

  describe "filter/3" do
    test "empty query returns all items" do
      items = ["apple", "banana", "cherry"]
      assert Fuzzy.filter(items, "", & &1) == items
    end

    test "whitespace-only query returns all items" do
      items = ["apple", "banana"]
      assert Fuzzy.filter(items, "   ", & &1) == items
    end

    test "filters non-matching items" do
      items = ["apple", "banana", "apricot"]
      result = Fuzzy.filter(items, "ap", & &1)
      assert "apple" in result
      assert "apricot" in result
      refute "banana" in result
    end

    test "sorts by score ascending (best first)" do
      items = ["axbxc", "abc", "axxxxbc"]
      [first | _] = Fuzzy.filter(items, "abc", & &1)
      assert first == "abc"
    end

    test "accepts custom text extractor" do
      items = [%{name: "foo"}, %{name: "bar"}, %{name: "fob"}]
      result = Fuzzy.filter(items, "fo", & &1.name)
      names = Enum.map(result, & &1.name)
      assert "foo" in names
      assert "fob" in names
      refute "bar" in names
    end

    test "space-separated tokens must all match" do
      items = ["foo bar baz", "foo qux", "bar baz"]
      result = Fuzzy.filter(items, "foo baz", & &1)
      assert result == ["foo bar baz"]
    end
  end
end
