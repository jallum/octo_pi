defmodule OctoPi.TUI.Components.BoxTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.{Box, Text}
  alias OctoPi.TUI.WrapAnsi

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\[[0-9;]*m/, "")
  end

  # ── Basic box rendering ─────────────────────────────────────────

  describe "render/2 with border" do
    test "renders bordered box around content" do
      box = Box.new(border: true) |> Box.add_child(%Text{content: "hello"})
      lines = Box.render(box, 20)
      stripped = Enum.map(lines, &strip_ansi/1)

      assert hd(stripped) =~ "┌"
      assert hd(stripped) =~ "┐"
      assert List.last(stripped) =~ "└"
      assert List.last(stripped) =~ "┘"
      assert Enum.any?(stripped, &(&1 =~ "hello"))
    end

    test "title in top border" do
      box = Box.new(border: true, title: "Title") |> Box.add_child(%Text{content: "body"})
      lines = Box.render(box, 30)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert hd(stripped) =~ "Title"
    end

    test "rounded corners" do
      box = Box.new(border: true, rounded: true) |> Box.add_child(%Text{content: "x"})
      lines = Box.render(box, 20)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert hd(stripped) =~ "╭"
      assert hd(stripped) =~ "╮"
      assert List.last(stripped) =~ "╰"
      assert List.last(stripped) =~ "╯"
    end

    test "content is padded inside border" do
      box = Box.new(border: true, padding_x: 1) |> Box.add_child(%Text{content: "hi"})
      lines = Box.render(box, 20)
      stripped = Enum.map(lines, &strip_ansi/1)
      content_line = Enum.find(stripped, &(&1 =~ "hi"))
      assert content_line =~ "│ hi"
    end
  end

  # ── Borderless box (padding + bg only) ──────────────────────────

  describe "render/2 without border" do
    test "renders children with padding" do
      box = Box.new(padding_x: 2, padding_y: 1) |> Box.add_child(%Text{content: "hi"})
      lines = Box.render(box, 20)
      stripped = Enum.map(lines, &strip_ansi/1)

      assert hd(stripped) == ""
      assert List.last(stripped) == ""
      content = Enum.find(stripped, &(&1 =~ "hi"))
      assert String.starts_with?(content, "  ")
    end

    test "empty children renders nothing" do
      box = Box.new()
      assert Box.render(box, 80) == []
    end
  end

  # ── Background function ─────────────────────────────────────────

  describe "background function" do
    test "applies bg_fn to each line" do
      bg_fn = fn text -> "\e[42m#{text}\e[49m" end
      box = Box.new(bg_fn: bg_fn) |> Box.add_child(%Text{content: "colored"})
      lines = Box.render(box, 20)
      assert Enum.all?(lines, &(&1 =~ "\e[42m"))
    end
  end

  # ── Border color ────────────────────────────────────────────────

  describe "border color" do
    test "applies color function to border chars" do
      color_fn = fn text -> "\e[34m#{text}\e[39m" end
      box = Box.new(border: true, border_color: color_fn) |> Box.add_child(%Text{content: "x"})
      lines = Box.render(box, 20)
      assert hd(lines) =~ "\e[34m"
    end
  end

  # ── Width handling ──────────────────────────────────────────────

  describe "width" do
    test "border lines fill to width" do
      box = Box.new(border: true) |> Box.add_child(%Text{content: "x"})
      lines = Box.render(box, 20)
      stripped = Enum.map(lines, &strip_ansi/1)
      top = hd(stripped)
      assert WrapAnsi.visible_width(top) == 20
    end
  end

  # ── Child management ────────────────────────────────────────────

  describe "add_child/2" do
    test "adds children" do
      box = Box.new() |> Box.add_child(%Text{content: "a"}) |> Box.add_child(%Text{content: "b"})
      assert length(box.children) == 2
    end
  end

  describe "clear/1" do
    test "removes all children" do
      box = Box.new() |> Box.add_child(%Text{content: "a"}) |> Box.clear()
      assert box.children == []
    end
  end
end
