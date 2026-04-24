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

  defp shift_enter, do: %Key{key: :enter, modifiers: [:shift]}
  defp move_right(input, n), do: Enum.reduce(1..n, input, fn _, s -> press(s, key(:right)) end)

  # --- tests ---

  describe "render/2" do
    test "renders the plain value as a single line" do
      assert ["hello"] = Input.render(%Input{value: "hello"}, 80)
    end

    test "renders empty value as an empty line" do
      assert [""] = Input.render(%Input{value: ""}, 80)
    end

    test "wraps value at display width" do
      assert ["he", "ll", "o"] = Input.render(%Input{value: "hello"}, 2)
    end

    test "wraps CJK characters respecting display width" do
      assert ["abc日", "本"] = Input.render(%Input{value: "abc日本"}, 5)
    end

    test "CJK char that does not fit wraps to next line" do
      assert ["abcd", "日"] = Input.render(%Input{value: "abcd日"}, 5)
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

  describe "cursor_rc/2" do
    test "cursor at start is {0, 0}" do
      assert {0, 0} = Input.cursor_rc(%Input{value: "hello", cursor: 0}, 80)
    end

    test "cursor tracks display columns" do
      assert {0, 3} = Input.cursor_rc(%Input{value: "hello", cursor: 3}, 80)
    end

    test "cursor wraps to next line at width boundary" do
      assert {1, 0} = Input.cursor_rc(%Input{value: "hello", cursor: 5}, 5)
    end

    test "cursor on second wrapped line" do
      assert {1, 1} = Input.cursor_rc(%Input{value: "helloworld", cursor: 6}, 5)
    end

    test "CJK chars are two display columns" do
      assert {0, 4} = Input.cursor_rc(%Input{value: "日本", cursor: 2}, 80)
    end

    test "CJK wrap: cursor after wrapped CJK" do
      # "abcd日" width=5: 'abcd' fills 4 cols, '日' (2 wide) wraps
      assert {1, 2} = Input.cursor_rc(%Input{value: "abcd日", cursor: 5}, 5)
    end

    test "empty value cursor at {0, 0}" do
      assert {0, 0} = Input.cursor_rc(%Input{value: "", cursor: 0}, 80)
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

  describe "handle_key/2 — word movement" do
    test "Alt+B moves cursor backward one word" do
      s = %Input{value: "hello world", cursor: 11}
      assert %Input{cursor: 6} = press(s, alt(?b))
    end

    test "Alt+B skips whitespace then word" do
      s = %Input{value: "hello   world", cursor: 8}
      assert %Input{cursor: 0} = press(s, alt(?b))
    end

    test "Alt+B at start stays at 0" do
      s = %Input{value: "hello", cursor: 0}
      assert %Input{cursor: 0} = press(s, alt(?b))
    end

    test "Alt+F moves cursor forward one word" do
      s = %Input{value: "hello world", cursor: 0}
      assert %Input{cursor: 5} = press(s, alt(?f))
    end

    test "Alt+F skips whitespace then word" do
      s = %Input{value: "hello   world", cursor: 5}
      assert %Input{cursor: 13} = press(s, alt(?f))
    end

    test "Alt+F at end stays at end" do
      s = %Input{value: "hello", cursor: 5}
      assert %Input{cursor: 5} = press(s, alt(?f))
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

  # ── Multiline editing ─────────────────────────────────────────

  describe "Shift+Enter — newline insertion" do
    test "inserts newline at cursor" do
      input = type(%Input{}, "hello") |> press(shift_enter())
      assert input.value == "hello\n"
      assert input.cursor == 6
    end

    test "inserts newline in middle of text" do
      input =
        type(%Input{}, "helloworld") |> press(ctrl(?a)) |> move_right(5) |> press(shift_enter())

      assert input.value == "hello\nworld"
      assert input.cursor == 6
    end
  end

  describe "multiline render/2" do
    test "splits on newlines and renders each logical line" do
      lines = Input.render(%Input{value: "hello\nworld"}, 80)
      assert lines == ["hello", "world"]
    end

    test "wraps each logical line separately" do
      lines = Input.render(%Input{value: "abcde\nfg"}, 3)
      assert lines == ["abc", "de", "fg"]
    end

    test "empty lines preserved" do
      lines = Input.render(%Input{value: "a\n\nb"}, 80)
      assert lines == ["a", "", "b"]
    end
  end

  describe "multiline cursor_rc/2" do
    test "cursor on second logical line" do
      assert {1, 2} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 8}, 80)
    end

    test "cursor at start of second line" do
      assert {1, 0} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 6}, 80)
    end

    test "cursor on newline character itself" do
      assert {0, 5} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 5}, 80)
    end

    test "cursor after wrapping + newline" do
      # "abcde\nfg" at width 3: "abc" "de" "fg"
      # cursor at 'f' = grapheme 6, should be row 2 col 0
      assert {2, 0} = Input.cursor_rc(%Input{value: "abcde\nfg", cursor: 6}, 3)
    end
  end

  describe "vertical navigation — Up/Down" do
    test "down arrow moves to next visual line" do
      input = %Input{value: "hello\nworld", cursor: 2}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "up arrow moves to previous visual line" do
      input = %Input{value: "hello\nworld", cursor: 8}
      input = press(input, key(:up))
      assert input.cursor == 2
    end

    test "down clamps to shorter line" do
      input = %Input{value: "hello\nab", cursor: 4}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "up at first visual line is no-op" do
      input = %Input{value: "hello\nworld", cursor: 2}
      input = press(input, key(:up))
      assert input.cursor == 2
    end

    test "down at last visual line is no-op" do
      input = %Input{value: "hello\nworld", cursor: 8}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "down navigates through wrapped lines" do
      # "abcde" at width 3: "abc" "de"
      input = %Input{value: "abcde", cursor: 1, width: 3}
      input = press(input, key(:down))
      assert input.cursor == 4
    end
  end

  describe "page navigation" do
    test "Page Down moves down by page size" do
      lines = Enum.map_join(1..20, "\n", &"line#{&1}")
      input = %Input{value: lines, cursor: 0}
      input = press(input, key(:page_down))
      assert input.cursor > 0
    end

    test "Page Up moves up by page size" do
      lines = Enum.map_join(1..20, "\n", &"line#{&1}")
      input = %Input{value: lines, cursor: String.length(lines)}
      input = press(input, key(:page_up))
      assert input.cursor < String.length(lines)
    end
  end

  describe "line-aware kill operations" do
    test "Ctrl+K kills to end of current logical line, not end of all text" do
      input = %Input{value: "hello\nworld", cursor: 2} |> press(ctrl(?k))
      assert input.value == "he\nworld"
    end

    test "Ctrl+K at end of line kills the newline" do
      input = %Input{value: "hello\nworld", cursor: 5} |> press(ctrl(?k))
      assert input.value == "helloworld"
    end

    test "Ctrl+U kills to start of current logical line" do
      input = %Input{value: "hello\nworld", cursor: 8} |> press(ctrl(?u))
      assert input.value == "hello\nrld"
    end

    test "Ctrl+A moves to start of current logical line" do
      input = %Input{value: "hello\nworld", cursor: 8} |> press(ctrl(?a))
      assert input.cursor == 6
    end

    test "Ctrl+E moves to end of current logical line" do
      input = %Input{value: "hello\nworld", cursor: 6} |> press(ctrl(?e))
      assert input.cursor == 11
    end

    test "Home moves to start of current logical line" do
      input = %Input{value: "hello\nworld", cursor: 8} |> press(key(:home))
      assert input.cursor == 6
    end

    test "End moves to end of current logical line" do
      input = %Input{value: "hello\nworld", cursor: 6} |> press(key(:end))
      assert input.cursor == 11
    end
  end

  describe "backspace at line boundary" do
    test "backspace at start of second line merges lines" do
      input = %Input{value: "hello\nworld", cursor: 6} |> press(key(:backspace))
      assert input.value == "helloworld"
      assert input.cursor == 5
    end
  end

  describe "multiline paste" do
    test "paste preserves newlines" do
      input = %Input{} |> Input.paste("hello\nworld")
      assert input.value == "hello\nworld"
      assert input.cursor == 11
    end

    test "paste normalizes \\r\\n to \\n" do
      input = %Input{} |> Input.paste("hello\r\nworld")
      assert input.value == "hello\nworld"
    end
  end

  describe "scroll_offset/2" do
    test "returns 0 when content fits" do
      input = %Input{value: "hello\nworld", cursor: 0}
      assert Input.scroll_offset(input, 80, 10) == 0
    end

    test "scrolls to keep cursor visible" do
      lines = Enum.map_join(1..20, "\n", &"line#{&1}")
      input = %Input{value: lines, cursor: String.length(lines)}
      offset = Input.scroll_offset(input, 80, 5)
      assert offset > 0
    end
  end

  # ── Input history ──────────────────────────────────────────────

  describe "history" do
    test "Up at top of input recalls previous entry" do
      input = %Input{value: "", history: ["older", "recent"], history_index: nil}
      input = press(input, key(:up))
      assert input.value == "recent"
      assert input.history_index == 1
    end

    test "successive Up walks further back" do
      input = %Input{value: "", history: ["first", "second", "third"], history_index: nil}
      input = input |> press(key(:up)) |> press(key(:up))
      assert input.value == "second"
      assert input.history_index == 1
    end

    test "Up stops at oldest entry" do
      input = %Input{value: "", history: ["only"], history_index: nil}
      input = input |> press(key(:up)) |> press(key(:up))
      assert input.value == "only"
      assert input.history_index == 0
    end

    test "Down after Up walks forward" do
      input = %Input{value: "", history: ["a", "b", "c"], history_index: nil}
      input = input |> press(key(:up)) |> press(key(:up)) |> press(key(:down))
      assert input.value == "c"
      assert input.history_index == 2
    end

    test "Down past newest restores saved input" do
      input = %Input{value: "draft", history: ["old"], history_index: nil}
      input = input |> press(key(:up)) |> press(key(:down))
      assert input.value == "draft"
      assert input.history_index == nil
    end

    test "current input is preserved when entering history" do
      input = %Input{value: "wip", history: ["prev"], history_index: nil}
      input = press(input, key(:up))
      assert input.saved_input == "wip"
      assert input.value == "prev"
    end

    test "empty history is a no-op for Up" do
      input = %Input{value: "hi", history: [], history_index: nil}
      input = press(input, key(:up))
      assert input.value == "hi"
      assert input.history_index == nil
    end

    test "push_history adds entry and resets index" do
      input = %Input{value: "done", history: ["old"]}
      input = Input.push_history(input, "done")
      assert input.history == ["old", "done"]
      assert input.history_index == nil
      assert input.saved_input == nil
    end

    test "push_history deduplicates consecutive entries" do
      input = %Input{history: ["a", "b"]}
      input = Input.push_history(input, "b")
      assert input.history == ["a", "b"]
    end

    test "push_history respects max size" do
      history = Enum.map(1..1000, &to_string/1)
      input = %Input{history: history}
      input = Input.push_history(input, "new")
      assert length(input.history) == 1000
      assert List.last(input.history) == "new"
      assert hd(input.history) == "2"
    end

    test "typing after recalling resets history browsing" do
      input = %Input{value: "", history: ["old"], history_index: nil}
      input = input |> press(key(:up)) |> Input.insert("x")
      assert input.history_index == nil
      assert input.value == "oldx"
    end
  end
end
