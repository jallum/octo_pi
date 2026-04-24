defmodule OctoPi.TUI.Components.MarkdownTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp render(text, width \\ 80) do
    md = Markdown.new(text, @theme)
    Markdown.render(md, width)
  end

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\[[0-9;]*m/, "")
  end

  # ── Headings ────────────────────────────────────────────────────

  describe "headings" do
    test "h1 renders bold + underline + heading color" do
      [line | _] = render("# Hello")
      stripped = strip_ansi(line)
      assert stripped == "Hello"
      assert line =~ ~r/\e\[/
    end

    test "h2 renders bold + heading color" do
      [line | _] = render("## World")
      stripped = strip_ansi(line)
      assert stripped == "World"
    end

    test "h3+ renders with prefix" do
      [line | _] = render("### Section")
      stripped = strip_ansi(line)
      assert stripped =~ "### Section"
    end

    test "heading followed by paragraph has spacing" do
      lines = render("# Title\n\nParagraph")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert "" in stripped
    end
  end

  # ── Paragraphs ──────────────────────────────────────────────────

  describe "paragraphs" do
    test "plain text renders as-is" do
      lines = render("Hello world")
      assert strip_ansi(hd(lines)) == "Hello world"
    end

    test "multiple paragraphs separated by blank line" do
      lines = render("First paragraph\n\nSecond paragraph")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert "First paragraph" in stripped
      assert "Second paragraph" in stripped
    end
  end

  # ── Inline formatting ──────────────────────────────────────────

  describe "inline formatting" do
    test "bold text" do
      [line | _] = render("**bold**")
      stripped = strip_ansi(line)
      assert stripped == "bold"
      assert line =~ "\e[1m"
    end

    test "italic text" do
      [line | _] = render("*italic*")
      stripped = strip_ansi(line)
      assert stripped == "italic"
      assert line =~ "\e[3m"
    end

    test "code span" do
      [line | _] = render("`code`")
      stripped = strip_ansi(line)
      assert stripped == "code"
    end

    test "strikethrough" do
      [line | _] = render("~~struck~~")
      stripped = strip_ansi(line)
      assert stripped == "struck"
      assert line =~ "\e[9m"
    end

    test "mixed inline formatting" do
      [line | _] = render("plain **bold** and *italic*")
      stripped = strip_ansi(line)
      assert stripped =~ "plain"
      assert stripped =~ "bold"
      assert stripped =~ "italic"
    end
  end

  # ── Code blocks ─────────────────────────────────────────────────

  describe "fenced code blocks" do
    test "renders with language label and border" do
      md = "```elixir\nIO.puts(\"hi\")\n```"
      lines = render(md)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "```elixir"))
      assert Enum.any?(stripped, &(&1 =~ "IO.puts"))
      assert Enum.any?(stripped, &(&1 == "```"))
    end

    test "code block without language" do
      md = "```\nfoo\n```"
      lines = render(md)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "foo"))
    end
  end

  # ── Lists ───────────────────────────────────────────────────────

  describe "unordered lists" do
    test "renders bullet items" do
      md = "- one\n- two\n- three"
      lines = render(md)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "one"))
      assert Enum.any?(stripped, &(&1 =~ "two"))
      assert Enum.any?(stripped, &(&1 =~ "three"))
    end

    test "items have bullet markers" do
      md = "- alpha"
      lines = render(md)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "- alpha"))
    end
  end

  describe "ordered lists" do
    test "renders numbered items" do
      md = "1. first\n2. second"
      lines = render(md)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "1."))
      assert Enum.any?(stripped, &(&1 =~ "first"))
    end
  end

  # ── Blockquotes ─────────────────────────────────────────────────

  describe "blockquotes" do
    test "renders with border" do
      lines = render("> quoted text")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "│"))
      assert Enum.any?(stripped, &(&1 =~ "quoted text"))
    end
  end

  # ── Horizontal rules ────────────────────────────────────────────

  describe "horizontal rules" do
    test "renders as line" do
      lines = render("---")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "─"))
    end
  end

  # ── Links ───────────────────────────────────────────────────────

  describe "links" do
    test "renders link text" do
      lines = render("[click here](https://example.com)")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "click here"))
    end

    test "shows URL when different from text" do
      lines = render("[click](https://example.com)")
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "example.com"))
    end
  end

  # ── Empty input ─────────────────────────────────────────────────

  describe "empty input" do
    test "empty string returns empty list" do
      assert render("") == []
    end

    test "whitespace-only returns empty list" do
      assert render("   \n  \n  ") == []
    end
  end

  # ── Component interface ─────────────────────────────────────────

  describe "Component behaviour" do
    test "implements render/2" do
      md = Markdown.new("hello", @theme)
      lines = Markdown.render(md, 80)
      assert is_list(lines)
    end
  end

  # ── Padding ─────────────────────────────────────────────────────

  describe "padding" do
    test "horizontal padding adds margins" do
      md = Markdown.new("hello", @theme, padding_x: 2)
      [line | _] = Markdown.render(md, 80)
      assert String.starts_with?(line, "  ")
    end

    test "vertical padding adds empty lines" do
      md = Markdown.new("hello", @theme, padding_y: 1)
      lines = Markdown.render(md, 80)
      assert hd(lines) == ""
      assert List.last(lines) == ""
    end
  end
end
