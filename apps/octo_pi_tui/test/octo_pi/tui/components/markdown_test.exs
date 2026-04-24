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

  # ── Upstream markdown.test.ts / Nested lists ───────────────────

  describe "nested lists" do
    defp strip_md(lines), do: Enum.map(lines, &strip_ansi/1)

    test "renders simple nested list" do
      md = """
      - Item 1
        - Nested 1.1
        - Nested 1.2
      - Item 2
      """

      plain = md |> render() |> strip_md()
      assert Enum.any?(plain, &String.contains?(&1, "- Item 1"))
      assert Enum.any?(plain, &String.contains?(&1, "  - Nested 1.1"))
      assert Enum.any?(plain, &String.contains?(&1, "  - Nested 1.2"))
      assert Enum.any?(plain, &String.contains?(&1, "- Item 2"))
    end

    test "renders deeply nested list (4 levels)" do
      md = """
      - Level 1
        - Level 2
          - Level 3
            - Level 4
      """

      plain = md |> render() |> strip_md()
      assert Enum.any?(plain, &String.contains?(&1, "- Level 1"))
      assert Enum.any?(plain, &String.contains?(&1, "  - Level 2"))
      assert Enum.any?(plain, &String.contains?(&1, "    - Level 3"))
      assert Enum.any?(plain, &String.contains?(&1, "      - Level 4"))
    end

    test "renders ordered nested list" do
      md = """
      1. First
         1. Nested first
         2. Nested second
      2. Second
      """

      plain = md |> render() |> strip_md()
      assert Enum.any?(plain, &String.contains?(&1, "1. First"))
      assert Enum.any?(plain, &String.contains?(&1, "  1. Nested first"))
      assert Enum.any?(plain, &String.contains?(&1, "  2. Nested second"))
      assert Enum.any?(plain, &String.contains?(&1, "2. Second"))
    end

    test "maintains numbering when code blocks are interleaved between items" do
      md = """
      1. First item

      ```typescript
      // code block
      ```

      2. Second item

      ```typescript
      // another code block
      ```

      3. Third item
      """

      plain = md |> render() |> strip_md()
      numbered = Enum.filter(plain, &(&1 |> String.trim() |> String.match?(~r/^\d+\./)))
      assert length(numbered) == 3
      assert String.trim(Enum.at(numbered, 0)) |> String.starts_with?("1.")
      assert String.trim(Enum.at(numbered, 1)) |> String.starts_with?("2.")
      assert String.trim(Enum.at(numbered, 2)) |> String.starts_with?("3.")
    end

    test "renders mixed ordered + unordered nested lists" do
      md = """
      1. Ordered item
         - Unordered nested
         - Another nested
      2. Second ordered
         - More nested
      """

      plain = md |> render() |> strip_md()
      assert Enum.any?(plain, &String.contains?(&1, "1. Ordered item"))
      assert Enum.any?(plain, &String.contains?(&1, "  - Unordered nested"))
      assert Enum.any?(plain, &String.contains?(&1, "2. Second ordered"))
    end
  end

  # ── Upstream markdown.test.ts / Strikethrough syntax ────────────

  describe "strikethrough syntax (upstream parity)" do
    test "renders ~~text~~ as strikethrough" do
      output = render("Use ~~strikethrough~~ here") |> Enum.join("\n")
      plain = strip_ansi(output)
      assert String.contains?(output, "\e[9m")
      assert String.contains?(plain, "strikethrough")
      refute String.contains?(plain, "~~strikethrough~~")
    end

    test "keeps ~text~ as plain text (single tilde)" do
      output = render("Use ~strikethrough~ literally") |> Enum.join("\n")
      plain = strip_ansi(output)
      assert String.contains?(plain, "~strikethrough~")
      refute String.contains?(output, "\e[9m")
    end
  end

  # ── Upstream markdown.test.ts / Spacing after code blocks ──────

  describe "spacing after code blocks (upstream parity)" do
    test "one blank line between code block and following paragraph" do
      md = """
      hello world

      ```js
      const hello = "world";
      ```

      again, hello world
      """

      plain =
        md |> render() |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))

      closing_idx = Enum.find_index(plain, &(&1 == "```"))
      assert is_integer(closing_idx)
      after_closing = Enum.drop(plain, closing_idx + 1)
      empty_count = Enum.find_index(after_closing, &(&1 != ""))
      assert empty_count == 1
    end

    test "no trailing blank line when code block is the last rendered block" do
      for md <- [
            "```js\nconst hello = 'world';\n```",
            "hello world\n\n```js\nconst hello = 'world';\n```"
          ] do
        plain = md |> render() |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))

        refute List.last(plain) == "",
               "code-block-as-last should not end blank: #{inspect(plain)}"
      end
    end
  end

  # ── Upstream markdown.test.ts / Spacing after dividers ──────────

  describe "spacing after dividers (upstream parity)" do
    test "one blank line between divider and following paragraph" do
      md = "hello world\n\n---\n\nagain, hello world"
      plain = md |> render() |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))
      divider_idx = Enum.find_index(plain, &String.contains?(&1, "─"))
      assert is_integer(divider_idx)
      after_div = Enum.drop(plain, divider_idx + 1)
      empty_count = Enum.find_index(after_div, &(&1 != ""))
      assert empty_count == 1
    end

    test "no trailing blank line when divider is the last rendered block" do
      plain = "---" |> render() |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))
      refute List.last(plain) == ""
    end
  end

  # ── Upstream markdown.test.ts / Spacing after headings ──────────

  describe "spacing after headings (upstream parity)" do
    test "one blank line between heading and following paragraph" do
      plain =
        "# Hello\n\nThis is a paragraph"
        |> render()
        |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))

      head_idx = Enum.find_index(plain, &String.contains?(&1, "Hello"))
      assert is_integer(head_idx)
      after_head = Enum.drop(plain, head_idx + 1)
      assert Enum.find_index(after_head, &(&1 != "")) == 1
    end

    test "no trailing blank line when heading is the last rendered block" do
      plain = "# Hello" |> render() |> Enum.map(&(strip_ansi(&1) |> String.trim_trailing()))
      refute List.last(plain) == ""
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
