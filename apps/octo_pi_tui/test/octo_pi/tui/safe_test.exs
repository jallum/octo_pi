defmodule OctoPi.TUI.SafeTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Safe

  describe "sanitize/1" do
    test "plain text passes through" do
      assert Safe.sanitize("hello world") == "hello world"
    end

    test "SGR color codes pass through" do
      assert Safe.sanitize("\e[31mred\e[0m") == "\e[31mred\e[0m"
    end

    test "SGR bold/italic/underline pass through" do
      text = "\e[1mbold\e[22m \e[3mitalic\e[23m \e[4munderline\e[24m"
      assert Safe.sanitize(text) == text
    end

    test "SGR 256-color and RGB pass through" do
      text = "\e[38;5;196mred\e[0m \e[48;2;0;128;255mbg\e[0m"
      assert Safe.sanitize(text) == text
    end

    test "cursor positioning is stripped" do
      assert Safe.sanitize("before\e[5;5Hafter") == "beforeafter"
    end

    test "cursor movement sequences are stripped" do
      assert Safe.sanitize("a\e[Ab\e[Bc\e[Cd\e[De") == "abcde"
    end

    test "clear screen is stripped" do
      assert Safe.sanitize("before\e[2Jafter") == "beforeafter"
    end

    test "clear to end of line is stripped" do
      assert Safe.sanitize("text\e[Kmore") == "textmore"
    end

    test "OSC 0 title change is stripped (BEL terminated)" do
      assert Safe.sanitize("before\e]0;evil title\x07after") == "beforeafter"
    end

    test "OSC 0 title change is stripped (ST terminated)" do
      assert Safe.sanitize("before\e]0;evil title\e\\after") == "beforeafter"
    end

    test "DCS is stripped" do
      assert Safe.sanitize("before\ePsome;data\e\\after") == "beforeafter"
    end

    test "APC is stripped" do
      assert Safe.sanitize("before\e_app data\e\\after") == "beforeafter"
    end

    test "PM is stripped" do
      assert Safe.sanitize("before\e^private\e\\after") == "beforeafter"
    end

    test "SS3 sequences are stripped" do
      assert Safe.sanitize("before\eOAafter") == "beforeafter"
    end

    test "mixed safe and unsafe sequences" do
      text = "\e[31mred\e[0m\e[5;5H\e]0;title\x07normal"
      assert Safe.sanitize(text) == "\e[31mred\e[0mnormal"
    end

    test "incomplete CSI at end of string" do
      assert Safe.sanitize("text\e[") == "text"
    end

    test "bare ESC at end of string" do
      assert Safe.sanitize("text\e") == "text"
    end

    test "unicode content preserved" do
      assert Safe.sanitize("日本語 🇺🇸") == "日本語 🇺🇸"
    end

    test "empty string" do
      assert Safe.sanitize("") == ""
    end
  end
end
