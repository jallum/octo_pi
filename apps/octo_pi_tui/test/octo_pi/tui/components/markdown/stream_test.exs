defmodule OctoPi.TUI.Components.Markdown.StreamTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Markdown.Lexer
  alias OctoPi.TUI.Components.Markdown.Stream

  describe "blocks/1 equivalence" do
    test "empty stream returns no blocks" do
      assert Stream.blocks(Stream.new()) == []
    end

    test "single paragraph matches full lex" do
      text = "Hello **world**."
      s = Stream.new(text)
      assert Stream.blocks(s) == Lexer.tokenize(text)
    end

    test "multiple paragraphs match full lex" do
      text = "Para one.\n\nPara two with *em*.\n\nPara three."
      s = Stream.new(text)
      assert Stream.blocks(s) == Lexer.tokenize(text)
    end

    test "fenced code with blank line inside is preserved" do
      text = "Before.\n\n```elixir\ndef a, do: 1\n\ndef b, do: 2\n```\n\nAfter."
      s = Stream.new(text)
      assert Stream.blocks(s) == Lexer.tokenize(text)
    end

    test "list followed by paragraph matches full lex" do
      text = "- one\n- two\n- three\n\nA paragraph."
      s = Stream.new(text)
      assert Stream.blocks(s) == Lexer.tokenize(text)
    end

    test "blockquote then heading matches full lex" do
      text = "> a quote\n> still quoting\n\n# Heading\n\nBody."
      s = Stream.new(text)
      assert Stream.blocks(s) == Lexer.tokenize(text)
    end
  end

  describe "incremental put/2" do
    test "growing text byte-by-byte yields the same final AST" do
      final = "Para one.\n\nPara two.\n\nPara three."

      s =
        Enum.reduce(1..byte_size(final), Stream.new(), fn n, acc ->
          Stream.put(acc, binary_part(final, 0, n))
        end)

      assert Stream.blocks(s) == Lexer.tokenize(final)
    end

    test "checkpoint advances past completed paragraphs" do
      s =
        Stream.new()
        |> Stream.put("Para one.\n\n")
        |> Stream.put("Para one.\n\nPara two ")

      assert s.checkpoint > 0
      # `Para two ` is unlexed tail; only the first paragraph is committed.
      assert length(s.committed) == 1
    end

    test "checkpoint does not advance into an open fence" do
      s = Stream.put(Stream.new(), "```elixir\ndef a, do: 1\n\ndef b, do: 2\n")

      # Fence still open — no committed blocks.
      assert s.checkpoint == 0
      assert s.committed == []
    end

    test "checkpoint advances after fence closes" do
      open = "```elixir\ndef a, do: 1\n```\n\n"
      s = Stream.put(Stream.new(), open)
      assert s.checkpoint > 0
      assert length(s.committed) == 1
    end
  end

  describe "reset on non-extending text" do
    test "shorter text resets state" do
      s = Stream.new("Para one.\n\nPara two.\n\n")
      assert s.checkpoint > 0

      reset = Stream.put(s, "Different.")
      assert reset.checkpoint == 0
      assert reset.committed == []
      assert Stream.blocks(reset) == Lexer.tokenize("Different.")
    end

    test "divergent text resets state" do
      s = Stream.new("Hello there.\n\n")
      reset = Stream.put(s, "Hello world.\n\n")
      assert Stream.blocks(reset) == Lexer.tokenize("Hello world.\n\n")
    end
  end
end
