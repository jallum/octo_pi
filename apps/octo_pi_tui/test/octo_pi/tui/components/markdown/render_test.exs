defmodule OctoPi.TUI.Components.Markdown.RenderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Markdown
  alias OctoPi.TUI.Components.Markdown.Render
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)
  @width 80

  defp one_shot(text, width \\ @width, opts \\ []) do
    md = Markdown.new(text, @theme, opts)
    Markdown.render(md, width) |> Enum.join("\n")
  end

  defp render_bytes(text, width \\ @width, opts \\ []) do
    @theme
    |> Render.new(width, opts)
    |> Render.put(text)
    |> Render.to_iolist()
    |> IO.iodata_to_binary()
  end

  describe "one-shot equivalence" do
    test "empty text produces empty output" do
      assert render_bytes("") == ""
    end

    test "single paragraph matches one-shot pipeline" do
      text = "Hello **world**."
      assert render_bytes(text) == one_shot(text)
    end

    test "multi-paragraph matches one-shot pipeline" do
      text = "Para one.\n\nPara two with *em*.\n\nPara three."
      assert render_bytes(text) == one_shot(text)
    end

    test "fenced code block matches one-shot" do
      text = "Before.\n\n```elixir\ndef a, do: 1\n\ndef b, do: 2\n```\n\nAfter."
      assert render_bytes(text) == one_shot(text)
    end

    test "list followed by paragraph matches one-shot" do
      text = "- one\n- two\n- three\n\nA paragraph."
      assert render_bytes(text) == one_shot(text)
    end

    test "blockquote then heading matches one-shot" do
      text = "> a quote\n> still quoting\n\n# Heading\n\nBody."
      assert render_bytes(text) == one_shot(text)
    end

    test "respects padding_x option (matches one-shot)" do
      text = "A paragraph."
      assert render_bytes(text, @width, padding_x: 2) == one_shot(text, @width, padding_x: 2)
    end
  end

  describe "incremental put/2" do
    test "byte-by-byte growth matches one-shot final output" do
      final = "Para one.\n\nPara two with *em*.\n\n# Heading\n\nThird."

      r =
        Enum.reduce(1..byte_size(final), Render.new(@theme, @width), fn n, acc ->
          Render.put(acc, binary_part(final, 0, n))
        end)

      assert IO.iodata_to_binary(Render.to_iolist(r)) == one_shot(final)
    end

    test "checkpoint advances past completed paragraphs" do
      r =
        Render.new(@theme, @width)
        |> Render.put("Para one.\n\n")
        |> Render.put("Para one.\n\nPara two ")

      assert r.checkpoint > 0
      assert r.checkpoint == byte_size("Para one.\n\n")
    end

    test "checkpoint does not advance into an open fence" do
      r =
        Render.new(@theme, @width)
        |> Render.put("```elixir\ndef a, do: 1\n\ndef b, do: 2\n")

      assert r.checkpoint == 0
      assert r.committed == []
    end

    test "checkpoint advances after fence closes" do
      r = Render.new(@theme, @width) |> Render.put("```elixir\ndef a, do: 1\n```\n\n")
      assert r.checkpoint > 0
    end

    test "identical put is a no-op" do
      r1 = Render.new(@theme, @width) |> Render.put("Hi.\n\n")
      r2 = Render.put(r1, "Hi.\n\n")
      assert r1 == r2
    end

    test "non-extending put resets state" do
      r =
        Render.new(@theme, @width)
        |> Render.put("Para one.\n\nPara two.\n\n")

      assert r.checkpoint > 0

      reset = Render.put(r, "Different.")
      assert IO.iodata_to_binary(Render.to_iolist(reset)) == one_shot("Different.")
    end
  end

  describe "finalize/1" do
    test "folds tail into committed and is idempotent against to_iolist" do
      text = "Para one.\n\nTail with no trailing blank"

      r = Render.new(@theme, @width) |> Render.put(text)
      {bytes, finalized} = Render.finalize(r)

      assert IO.iodata_to_binary(bytes) == one_shot(text)
      assert finalized.checkpoint == byte_size(text)
      assert IO.iodata_to_binary(Render.to_iolist(finalized)) == one_shot(text)
    end

    test "finalize on already-checkpointed text is a no-op" do
      text = "Para one.\n\n"
      r = Render.new(@theme, @width) |> Render.put(text)
      {bytes, finalized} = Render.finalize(r)
      assert IO.iodata_to_binary(bytes) == one_shot(text)
      assert finalized == r
    end
  end

  describe "resize/2 and retheme/2" do
    test "resize to same width is a no-op" do
      r = Render.new(@theme, @width) |> Render.put("Hi.")
      assert Render.resize(r, @width) == r
    end

    test "resize triggers a full rerun and matches one-shot at new width" do
      text =
        "A long paragraph that will wrap at narrow widths and produce different line breaks " <>
          "depending on the available content width."

      r = Render.new(@theme, 80) |> Render.put(text)
      r2 = Render.resize(r, 30)

      assert IO.iodata_to_binary(Render.to_iolist(r2)) == one_shot(text, 30)
    end

    test "retheme to same theme is a no-op" do
      r = Render.new(@theme, @width) |> Render.put("Hi.")
      assert Render.retheme(r, @theme) == r
    end

    test "retheme triggers a full rerun" do
      other = Theme.load_builtin(:light, :truecolor)
      text = "A **paragraph**.\n\nAnother."

      r = Render.new(@theme, @width) |> Render.put(text)
      r2 = Render.retheme(r, other)

      expected =
        Markdown.new(text, other) |> Markdown.render(@width) |> Enum.join("\n")

      assert IO.iodata_to_binary(Render.to_iolist(r2)) == expected
    end
  end

  describe "to_lines/1" do
    test "matches Markdown.render line shape" do
      text = "Para one.\n\nPara two."
      r = Render.new(@theme, @width) |> Render.put(text)
      assert Render.to_lines(r) == Markdown.new(text, @theme) |> Markdown.render(@width)
    end

    test "empty render returns []" do
      assert Render.to_lines(Render.new(@theme, @width)) == []
    end
  end
end
