defmodule OctoPi.TUI.Components.UserMessageTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.UserMessage
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  describe "render/2" do
    test "renders text content" do
      msg = UserMessage.new("hello world", @theme)
      lines = UserMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      assert Enum.any?(stripped, &(&1 =~ "hello world"))
    end

    test "renders markdown formatting" do
      msg = UserMessage.new("**bold** text", @theme)
      lines = UserMessage.render(msg, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[1m"))
    end

    test "wraps in OSC 133 command zones" do
      msg = UserMessage.new("hello", @theme)
      lines = UserMessage.render(msg, 80)
      first = hd(lines)
      last = List.last(lines)
      assert first =~ "\e]133;A\a"
      assert last =~ "\e]133;B\a"
    end

    test "applies background color" do
      msg = UserMessage.new("hello", @theme)
      lines = UserMessage.render(msg, 80)
      assert Enum.any?(lines, &(&1 =~ "\e[48;"))
    end

    test "empty text returns empty list" do
      msg = UserMessage.new("", @theme)
      assert UserMessage.render(msg, 80) == []
    end

    test "includes padding" do
      msg = UserMessage.new("hi", @theme)
      lines = UserMessage.render(msg, 80)
      stripped = Enum.map(lines, &strip_ansi/1)
      content_line = Enum.find(stripped, &(&1 =~ "hi"))
      assert String.starts_with?(content_line, " ")
    end
  end
end
