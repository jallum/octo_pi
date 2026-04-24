defmodule OctoPi.TUI.Components.InputTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Input
  alias OctoPi.TUI.Key

  # --- helpers ---

  defp ctrl(char), do: %Key{key: char, modifiers: [:ctrl]}
  defp alt(char), do: %Key{key: char, modifiers: [:alt]}
  defp key(name), do: %Key{key: name}
  defp undo_key, do: ctrl(?-)

  defp type(input, string) do
    string |> String.graphemes() |> Enum.reduce(input, &Input.insert(&2, &1))
  end

  defp press(input, key_spec) do
    case Input.handle_key(input, key_spec) do
      {new_input, _events} -> new_input
      new_input -> new_input
    end
  end

  defp move_right(input, n), do: Enum.reduce(1..n, input, fn _, s -> press(s, key(:right)) end)

  # --- tests ---

  describe "render/2" do
    test "renders the plain value as a single line" do
      assert ["hello"] = Input.render(%Input{value: "hello"}, 80)
    end

    test "renders empty value as an empty line" do
      assert [""] = Input.render(%Input{value: ""}, 80)
    end

    test "truncates to width" do
      assert ["he"] = Input.render(%Input{value: "hello"}, 2)
    end
  end

  describe "submission" do
    test "submits value including backslash on Enter" do
      input = %Input{} |> type("hello") |> type("\\")
      {_input, [{:submit, value}]} = Input.handle_key(input, key(:enter))
      assert value == "hello\\"
    end

    test "inserts backslash as regular character" do
      input = %Input{} |> type("\\") |> type("x")
      assert input.value == "\\x"
    end
  end

  describe "handle_key/2 — cursor movement" do
    test "left moves cursor one grapheme back" do
      s = %Input{value: "abc", cursor: 2}
      assert %Input{cursor: 1} = press(s, key(:left))
    end

    test "left at 0 stays at 0" do
      assert %Input{cursor: 0} = press(%Input{value: "abc", cursor: 0}, key(:left))
    end

    test "right moves cursor one grapheme forward" do
      s = %Input{value: "abc", cursor: 1}
      assert %Input{cursor: 2} = press(s, key(:right))
    end

    test "right at end stays at end" do
      s = %Input{value: "abc", cursor: 3}
      assert %Input{cursor: 3} = press(s, key(:right))
    end

    test "Ctrl+A moves cursor to start" do
      s = %Input{value: "abc", cursor: 2}
      assert %Input{cursor: 0} = press(s, ctrl(?a))
    end

    test "Ctrl+E moves cursor to end" do
      s = %Input{value: "abcde", cursor: 1}
      assert %Input{cursor: 5} = press(s, ctrl(?e))
    end

    test ":home moves to start, :end to end" do
      s = %Input{value: "xyz", cursor: 1}
      assert %Input{cursor: 0} = press(s, key(:home))
      assert %Input{cursor: 3} = press(s, key(:end))
    end
  end

  describe "handle_key/2 — editing" do
    test "backspace deletes grapheme before cursor" do
      s = %Input{value: "abc", cursor: 3}
      assert %Input{value: "ab", cursor: 2} = press(s, key(:backspace))
    end

    test "backspace at cursor 0 is no-op" do
      s = %Input{value: "abc", cursor: 0}
      assert %Input{value: "abc", cursor: 0} = press(s, key(:backspace))
    end

    test "backspace handles CJK correctly (grapheme-aware)" do
      s = %Input{value: "日本語", cursor: 2}
      assert %Input{value: "日語", cursor: 1} = press(s, key(:backspace))
    end

    test "delete removes grapheme at cursor" do
      s = %Input{value: "abc", cursor: 1}
      assert %Input{value: "ac", cursor: 1} = press(s, key(:delete))
    end
  end

  describe "insert/2" do
    test "inserts a char at cursor and advances cursor" do
      s = %Input{value: "ac", cursor: 1}
      assert %Input{value: "abc", cursor: 2} = Input.insert(s, "b")
    end

    test "insert CJK advances by 1 grapheme (not bytes)" do
      s = %Input{value: "", cursor: 0}
      assert %Input{value: "日", cursor: 1} = Input.insert(s, "日")
    end

  end

  describe "handle_key/2 — submit/cancel" do
    test "Enter yields {:submit, value} event" do
      s = %Input{value: "hi", cursor: 2}
      assert {%Input{}, [{:submit, "hi"}]} = Input.handle_key(s, key(:enter))
    end

    test "Escape yields :cancel event" do
      s = %Input{value: "hi"}
      assert {%Input{}, [:cancel]} = Input.handle_key(s, key(:escape))
    end
  end

  describe "Kill ring" do
    test "Ctrl+W saves deleted text to kill ring and Ctrl+Y yanks it" do
      input =
        %Input{}
        |> Input.set_value("foo bar baz")
        |> press(ctrl(?e))
        |> press(ctrl(?w))

      assert input.value == "foo bar "

      input = input |> press(ctrl(?a)) |> press(ctrl(?y))
      assert input.value == "bazfoo bar "
    end

    test "Ctrl+U saves deleted text to kill ring" do
      input =
        %Input{}
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?u))

      assert input.value == "world"

      input = press(input, ctrl(?y))
      assert input.value == "hello world"
    end

    test "Ctrl+K saves deleted text to kill ring" do
      input =
        %Input{}
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> press(ctrl(?k))

      assert input.value == ""

      input = press(input, ctrl(?y))
      assert input.value == "hello world"
    end

    test "Ctrl+Y does nothing when kill ring is empty" do
      input =
        %Input{}
        |> Input.set_value("test")
        |> press(ctrl(?e))
        |> press(ctrl(?y))

      assert input.value == "test"
    end

    test "Alt+Y cycles through kill ring after Ctrl+Y" do
      input =
        %Input{}
        |> Input.set_value("first")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("second")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("third")
        |> press(ctrl(?e))
        |> press(ctrl(?w))

      assert input.value == ""

      input = press(input, ctrl(?y))
      assert input.value == "third"

      input = press(input, alt(?y))
      assert input.value == "second"

      input = press(input, alt(?y))
      assert input.value == "first"

      input = press(input, alt(?y))
      assert input.value == "third"
    end

    test "Alt+Y does nothing if not preceded by yank" do
      input =
        %Input{}
        |> Input.set_value("test")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("other")
        |> press(ctrl(?e))
        |> Input.insert("x")

      assert input.value == "otherx"

      input = press(input, alt(?y))
      assert input.value == "otherx"
    end

    test "Alt+Y does nothing if kill ring has one entry" do
      input =
        %Input{}
        |> Input.set_value("only")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> press(ctrl(?y))

      assert input.value == "only"

      input = press(input, alt(?y))
      assert input.value == "only"
    end

    test "consecutive Ctrl+W accumulates into one kill ring entry" do
      input =
        %Input{}
        |> Input.set_value("one two three")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> press(ctrl(?w))
        |> press(ctrl(?w))

      assert input.value == ""

      input = press(input, ctrl(?y))
      assert input.value == "one two three"
    end

    test "non-delete actions break kill accumulation" do
      input =
        %Input{}
        |> Input.set_value("foo bar baz")
        |> press(ctrl(?e))
        |> press(ctrl(?w))

      assert input.value == "foo bar "

      input = Input.insert(input, "x")
      assert input.value == "foo bar x"

      input = press(input, ctrl(?w))
      assert input.value == "foo bar "

      input = press(input, ctrl(?y))
      assert input.value == "foo bar x"

      input = press(input, alt(?y))
      assert input.value == "foo bar baz"
    end

    test "non-yank actions break Alt+Y chain" do
      input =
        %Input{}
        |> Input.set_value("first")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("second")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("")

      input = press(input, ctrl(?y))
      assert input.value == "second"

      input = Input.insert(input, "x")
      assert input.value == "secondx"

      input = press(input, alt(?y))
      assert input.value == "secondx"
    end

    test "kill ring rotation persists after cycling" do
      input =
        %Input{}
        |> Input.set_value("first")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("second")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("third")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("")

      input = input |> press(ctrl(?y)) |> press(alt(?y))
      assert input.value == "second"

      input = input |> Input.insert("x") |> Input.set_value("")

      input = press(input, ctrl(?y))
      assert input.value == "second"
    end

    test "backward deletions prepend, forward deletions append during accumulation" do
      input =
        %Input{}
        |> Input.set_value("prefix|suffix")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?k))

      assert input.value == "prefix"

      input = press(input, ctrl(?y))
      assert input.value == "prefix|suffix"
    end

    test "Alt+D deletes word forward and saves to kill ring" do
      input =
        %Input{}
        |> Input.set_value("hello world test")
        |> press(ctrl(?a))
        |> press(alt(?d))

      assert input.value == " world test"

      input = press(input, alt(?d))
      assert input.value == " test"

      input = press(input, ctrl(?y))
      assert input.value == "hello world test"
    end

    test "handles yank in middle of text" do
      input =
        %Input{}
        |> Input.set_value("word")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?y))

      assert input.value == "hello wordworld"
    end

    test "handles yank-pop in middle of text" do
      input =
        %Input{}
        |> Input.set_value("FIRST")
        |> press(ctrl(?e))
        |> press(ctrl(?w))
        |> Input.set_value("SECOND")
        |> press(ctrl(?e))
        |> press(ctrl(?w))

      input =
        input
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> move_right(6)

      input = press(input, ctrl(?y))
      assert input.value == "hello SECONDworld"

      input = press(input, alt(?y))
      assert input.value == "hello FIRSTworld"
    end
  end

  describe "Undo" do
    test "does nothing when undo stack is empty" do
      input = press(%Input{}, undo_key())
      assert input.value == ""
    end

    test "coalesces consecutive word characters into one undo unit" do
      input = type(%Input{}, "hello world")
      assert input.value == "hello world"

      input = press(input, undo_key())
      assert input.value == "hello"

      input = press(input, undo_key())
      assert input.value == ""
    end

    test "undoes spaces one at a time" do
      input = type(%Input{}, "hello  ")
      assert input.value == "hello  "

      input = press(input, undo_key())
      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == "hello"

      input = press(input, undo_key())
      assert input.value == ""
    end

    test "undoes backspace" do
      input = type(%Input{}, "hello") |> press(key(:backspace))
      assert input.value == "hell"

      input = press(input, undo_key())
      assert input.value == "hello"
    end

    test "undoes forward delete" do
      input =
        type(%Input{}, "hello")
        |> press(ctrl(?a))
        |> press(key(:right))
        |> press(key(:delete))

      assert input.value == "hllo"

      input = press(input, undo_key())
      assert input.value == "hello"
    end

    test "undoes Ctrl+W (delete word backward)" do
      input = type(%Input{}, "hello world") |> press(ctrl(?w))
      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes Ctrl+K (delete to line end)" do
      input =
        type(%Input{}, "hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?k))

      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes Ctrl+U (delete to line start)" do
      input =
        type(%Input{}, "hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?u))

      assert input.value == "world"

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes yank" do
      input =
        type(%Input{}, "hello ")
        |> press(ctrl(?w))
        |> press(ctrl(?y))

      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == ""
    end

    test "undoes paste atomically" do
      input =
        %Input{}
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> move_right(5)
        |> Input.paste("beep boop")

      assert input.value == "hellobeep boop world"

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes Alt+D (delete word forward)" do
      input =
        %Input{}
        |> Input.set_value("hello world")
        |> press(ctrl(?a))
        |> press(alt(?d))

      assert input.value == " world"

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "cursor movement starts new undo unit" do
      input =
        type(%Input{}, "abc")
        |> press(ctrl(?a))
        |> press(ctrl(?e))
        |> type("de")

      assert input.value == "abcde"

      input = press(input, undo_key())
      assert input.value == "abc"

      input = press(input, undo_key())
      assert input.value == ""
    end
  end
end
