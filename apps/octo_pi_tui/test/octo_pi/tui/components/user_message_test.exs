defmodule OctoPi.TUI.Components.UserMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.UserMessage
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme
  alias OctoPi.TUI.VDOM

  @theme Theme.load_builtin(:dark, :truecolor)

  defp ctx(width \\ 80), do: %RenderContext{theme: @theme, width: width}

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp render_lines(msg, ctx) do
    {_, %VDOM.VLines{lines: lines}, _} = UserMessage.render(msg, ctx)
    lines
  end

  describe "render/2" do
    test "renders text content" do
      msg = UserMessage.new("hello world")
      {_, %VDOM.VLines{lines: lines}, frame_ms} = UserMessage.render(msg, ctx())
      assert frame_ms == nil
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "hello world"))
    end

    test "renders markdown formatting" do
      msg = UserMessage.new("**bold** text")
      lines = render_lines(msg, ctx())
      assert Enum.any?(lines, &(&1 =~ "\e[1m"))
    end

    test "wraps in OSC 133 command zones" do
      msg = UserMessage.new("hello")
      lines = render_lines(msg, ctx())
      first = hd(lines)
      last = List.last(lines)
      assert first =~ "\e]133;A\a"
      assert last =~ "\e]133;B\a"
    end

    test "applies background color" do
      msg = UserMessage.new("hello")
      lines = render_lines(msg, ctx())
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "empty text returns empty list" do
      msg = UserMessage.new("")
      assert {%UserMessage{}, %VDOM.VLines{lines: []}, nil} = UserMessage.render(msg, ctx())
    end

    test "includes padding" do
      msg = UserMessage.new("hi")
      lines = render_lines(msg, ctx())
      stripped = Enum.map(lines, &strip_ansi/1)
      content_line = Enum.find(stripped, &(&1 =~ "hi"))
      assert String.starts_with?(content_line, " ")
    end

    test "background extends to full terminal width" do
      msg = UserMessage.new("hi")
      lines = render_lines(msg, ctx(40))
      stripped = Enum.map(lines, &strip_ansi/1)

      Enum.each(stripped, fn line ->
        assert String.length(line) == 40,
               "line width #{String.length(line)} != 40: #{inspect(line)}"
      end)
    end
  end
end
