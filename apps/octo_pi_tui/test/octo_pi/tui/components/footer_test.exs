defmodule OctoPi.TUI.Components.FooterTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Footer

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

  describe "render/2" do
    test "renders 3 lines by default (pwd + stats + hints)" do
      lines = Footer.render(footer(), 80)
      assert length(lines) == 3
    end

    test "pwd line shows cwd" do
      lines = Footer.render(footer(), 80)
      assert strip_ansi(hd(lines)) =~ "/home/user/project"
    end

    test "pwd line includes git branch" do
      lines = Footer.render(footer(%{git_branch: "main"}), 80)
      assert strip_ansi(hd(lines)) =~ "(main)"
    end

    test "pwd line includes session name" do
      lines = Footer.render(footer(%{session_name: "my-session"}), 80)
      assert strip_ansi(hd(lines)) =~ "my-session"
    end

    test "stats line shows token counts" do
      f = footer(%{input_tokens: 5_000, output_tokens: 1_234})
      lines = Footer.render(f, 80)
      stats = strip_ansi(Enum.at(lines, 1))
      assert stats =~ "↑5.0k"
      assert stats =~ "↓1.2k"
    end

    test "stats line shows model name" do
      lines = Footer.render(footer(), 80)
      stats = strip_ansi(Enum.at(lines, 1))
      assert stats =~ "claude-opus-4-6"
    end

    test "stats line shows thinking level" do
      f = footer(%{thinking_level: "medium"})
      lines = Footer.render(f, 80)
      stats = strip_ansi(Enum.at(lines, 1))
      assert stats =~ "medium"
    end

    test "context percent > 90 renders in red" do
      f = footer(%{context_percent: 95.0})
      lines = Footer.render(f, 80)
      raw = Enum.at(lines, 1)
      assert raw =~ "\e[31m"
    end

    test "context percent > 70 renders in yellow" do
      f = footer(%{context_percent: 75.0})
      lines = Footer.render(f, 80)
      raw = Enum.at(lines, 1)
      assert raw =~ "\e[33m"
    end

    test "nil context percent shows ?" do
      f = footer(%{context_percent: nil})
      lines = Footer.render(f, 80)
      stats = strip_ansi(Enum.at(lines, 1))
      assert stats =~ "?%"
    end

    test "hints line shows shortcut keys" do
      lines = Footer.render(footer(), 80)
      hints = strip_ansi(Enum.at(lines, 2))
      assert hints =~ "Esc"
      assert hints =~ "Ctrl+C"
      assert hints =~ "/help"
    end

    test "extension statuses add a fourth line" do
      f = footer(%{extension_statuses: %{"mcp" => "connected", "auth" => "ready"}})
      lines = Footer.render(f, 80)
      assert length(lines) == 4
      ext = strip_ansi(Enum.at(lines, 3))
      assert ext =~ "connected"
      assert ext =~ "ready"
    end

    test "extension statuses sorted alphabetically" do
      f = footer(%{extension_statuses: %{"z_ext" => "Z", "a_ext" => "A"}})
      lines = Footer.render(f, 80)
      ext = strip_ansi(Enum.at(lines, 3))
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
