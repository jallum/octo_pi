defmodule OctoPi.TUI.Components.FooterTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.RenderContext

  defp strip_ansi(str), do: String.replace(str, ~r/\e\[[0-9;]*m/, "")

  defp footer(overrides \\ %{}) do
    struct!(
      Footer,
      Map.merge(
        %{cwd: "/home/user/project", model_id: "claude-opus-4-6", context_window: 200_000},
        overrides
      )
    )
  end

  defp ctx(width), do: %RenderContext{width: width, theme: nil}

  defp render_lines(footer, width \\ 80) do
    elem(Footer.render(footer, ctx(width)), 1).lines
  end

  describe "render/2" do
    test "renders 2 lines by default (pwd + stats)" do
      lines = render_lines(footer())
      assert length(lines) == 2
    end

    test "pwd line shows cwd" do
      lines = render_lines(footer())
      assert strip_ansi(hd(lines)) =~ "/home/user/project"
    end

    test "pwd line includes git branch" do
      lines = render_lines(footer(%{git_branch: "main"}))
      assert strip_ansi(hd(lines)) =~ "(main)"
    end

    test "pwd line includes session name" do
      lines = render_lines(footer(%{session_name: "my-session"}))
      assert strip_ansi(hd(lines)) =~ "my-session"
    end

    test "stats line shows token counts" do
      f = footer(%{input_tokens: 5_000, output_tokens: 1_234})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      assert stats =~ "↑5.0k"
      assert stats =~ "↓1.2k"
    end

    test "stats line shows token counts in correct order (input, output, cache)" do
      f = footer(%{input_tokens: 5_000, output_tokens: 1_234, cache_read: 500})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      # Check order: ↑ should come before ↓ which should come before R
      assert String.match?(stats, ~r/↑.*↓.*R/), "token counts should be in order ↑ ↓ R"
    end

    test "stats line shows cost when cost > 0" do
      f = footer(%{input_tokens: 5_000, output_tokens: 1_234, cost: 0.042})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      assert stats =~ "$0.042"
    end

    test "stats line shows cost after tokens (rightmost before model name)" do
      f = footer(%{input_tokens: 5_000, output_tokens: 1_234, cost: 0.042})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      # Cost should come before model name, after token counts
      # e.g. "↑5.0k ↓1.2k $0.042 claude-opus-4-6"
      assert String.match?(stats, ~r/(\$0\.042|\$0\.0+42).*claude-opus-4-6/), "cost should appear before model name"
    end

    test "stats line shows model name" do
      stats = strip_ansi(Enum.at(render_lines(footer()), 1))
      assert stats =~ "claude-opus-4-6"
    end

    test "stats line shows thinking level" do
      f = footer(%{thinking_level: "medium"})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      assert stats =~ "medium"
    end

    test "context percent > 90 renders in red" do
      f = footer(%{context_percent: 95.0})
      raw = Enum.at(render_lines(f), 1)
      assert raw =~ "\e[31m"
    end

    test "context percent > 70 renders in yellow" do
      f = footer(%{context_percent: 75.0})
      raw = Enum.at(render_lines(f), 1)
      assert raw =~ "\e[33m"
    end

    test "nil context percent shows ?" do
      f = footer(%{context_percent: nil})
      stats = strip_ansi(Enum.at(render_lines(f), 1))
      assert stats =~ "?%"
    end

    # Provider display removed per opi-276.9 fix
    # (provider prefix is no longer shown in the footer)

    test "extension statuses add a third line" do
      f = footer(%{extension_statuses: %{"mcp" => "connected", "auth" => "ready"}})
      lines = render_lines(f)
      assert length(lines) == 3
      ext = strip_ansi(Enum.at(lines, 2))
      assert ext =~ "connected"
      assert ext =~ "ready"
    end

    test "extension statuses sorted alphabetically" do
      f = footer(%{extension_statuses: %{"z_ext" => "Z", "a_ext" => "A"}})
      ext = strip_ansi(Enum.at(render_lines(f), 2))
      assert ext =~ ~r/A.*Z/
    end
  end

  describe "format_tokens/1" do
    test "small numbers" do
      assert "500" = Footer.format_tokens(500)
    end

    test "thousands" do
      assert "5.0k" = Footer.format_tokens(5_000)
      assert "15k" = Footer.format_tokens(15_000)
    end

    test "millions" do
      assert "1.5M" = Footer.format_tokens(1_500_000)
      assert "15M" = Footer.format_tokens(15_000_000)
    end
  end
end
