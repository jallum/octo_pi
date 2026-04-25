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

  defp border(width), do: String.duplicate("─", width)
  defp content_lines(lines), do: Enum.slice(lines, 1..-2//1)
  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  # --- tests ---

  describe "render/2 — border structure (ported from upstream editor.test.ts)" do
    test "empty input has exactly 3 lines (top border, content, bottom border)" do
      lines = Input.render(%Input{value: ""}, 80)
      assert length(lines) == 3
      assert hd(lines) == border(80)
      assert List.last(lines) == border(80)
    end

    test "single-line input has exactly 3 lines (top border, content, bottom border)" do
      lines = Input.render(%Input{value: "hello"}, 80)
      assert length(lines) == 3
      assert hd(lines) == border(80)
      assert List.last(lines) == border(80)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["hello"]
    end

    test "content lines sit between borders" do
      lines = Input.render(%Input{value: "hello"}, 80)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["hello"]
    end

    test "wraps at full width (no prefix)" do
      # width=4, layoutWidth=3 (1 col reserved for cursor)
      lines = Input.render(%Input{value: "hello"}, 4)
      assert hd(lines) == border(4)
      assert List.last(lines) == border(4)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["hel", "lo"]
    end

    test "wraps CJK characters respecting display width" do
      # width=5, lw=4: abc(3)+日(2)=5>4 → wraps
      lines = Input.render(%Input{value: "abc日本"}, 5)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["abc", "日本"]
    end

    test "CJK char that does not fit wraps to next line" do
      # width=6, lw=5: abcd(4)+日(2)=6>5 → wraps
      lines = Input.render(%Input{value: "abcd日"}, 6)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["abcd", "日"]
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

  describe "render/2 — visible cursor (ported from upstream editor.test.ts)" do
    @reverse_on "\e[7m"
    @reverse_off "\e[27m"

    test "empty input renders a reverse-video space as cursor" do
      lines = Input.render(%Input{value: "", cursor: 0}, 80)
      content = content_lines(lines)
      assert length(content) == 1
      [line] = content
      assert line =~ @reverse_on
      assert line =~ @reverse_off
    end

    test "cursor on a character highlights it in reverse video" do
      lines = Input.render(%Input{value: "hello", cursor: 1}, 80)
      [line] = content_lines(lines)
      assert line =~ "h" <> @reverse_on <> "e" <> @reverse_off <> "llo"
    end

    test "cursor at end of text renders reverse-video space" do
      lines = Input.render(%Input{value: "hi", cursor: 2}, 80)
      [line] = content_lines(lines)
      assert line =~ "hi" <> @reverse_on <> " " <> @reverse_off
    end
  end

  describe "cursor_rc/2" do
    test "cursor at start is row 1 col 0 (after top border)" do
      assert {1, 0} = Input.cursor_rc(%Input{value: "hello", cursor: 0}, 80)
    end

    test "cursor tracks display columns" do
      assert {1, 3} = Input.cursor_rc(%Input{value: "hello", cursor: 3}, 80)
    end

    test "cursor wraps to next row at width boundary" do
      # width=5, lw=4: "hello" → "hell"|"o", cursor 5 at row 1 col 1
      assert {2, 1} = Input.cursor_rc(%Input{value: "hello", cursor: 5}, 5)
    end

    test "cursor on second wrapped line" do
      # width=5, lw=4: "hell"|"owor"|"ld", cursor 6 → row 1, col 2
      assert {2, 2} = Input.cursor_rc(%Input{value: "helloworld", cursor: 6}, 5)
    end

    test "CJK chars are two display columns" do
      assert {1, 4} = Input.cursor_rc(%Input{value: "日本", cursor: 2}, 80)
    end

    test "CJK wrap: cursor after wrapped CJK" do
      # "abcd日" width=5: 'abcd' fills 4, '日' (2) wraps to next row
      assert {2, 2} = Input.cursor_rc(%Input{value: "abcd日", cursor: 5}, 5)
    end

    test "empty value cursor at row 1 col 0" do
      assert {1, 0} = Input.cursor_rc(%Input{value: "", cursor: 0}, 80)
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
      input = %Input{} |> type("hello") |> press(key(:backspace))
      assert input.value == "hell"

      input = press(input, undo_key())
      assert input.value == "hello"
    end

    test "undoes forward delete" do
      input =
        %Input{}
        |> type("hello")
        |> press(ctrl(?a))
        |> press(key(:right))
        |> press(key(:delete))

      assert input.value == "hllo"

      input = press(input, undo_key())
      assert input.value == "hello"
    end

    test "undoes Ctrl+W (delete word backward)" do
      input = %Input{} |> type("hello world") |> press(ctrl(?w))
      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes Ctrl+K (delete to line end)" do
      input =
        %Input{}
        |> type("hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?k))

      assert input.value == "hello "

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes Ctrl+U (delete to line start)" do
      input =
        %Input{}
        |> type("hello world")
        |> press(ctrl(?a))
        |> move_right(6)
        |> press(ctrl(?u))

      assert input.value == "world"

      input = press(input, undo_key())
      assert input.value == "hello world"
    end

    test "undoes yank" do
      input =
        %Input{}
        |> type("hello ")
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
        %Input{}
        |> type("abc")
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
      input = %Input{} |> type("hello") |> press(shift_enter())
      assert input.value == "hello\n"
      assert input.cursor == 6
    end

    test "inserts newline in middle of text" do
      input =
        %Input{} |> type("helloworld") |> press(ctrl(?a)) |> move_right(5) |> press(shift_enter())

      assert input.value == "hello\nworld"
      assert input.cursor == 6
    end
  end

  describe "multiline render/2" do
    test "splits on newlines and renders each logical line" do
      lines = Input.render(%Input{value: "hello\nworld"}, 80)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["hello", "world"]
    end

    test "wraps each logical line separately" do
      # width=3, lw=2: "abcde" → "ab"|"cd"|"e", "fg" → "fg"
      lines = Input.render(%Input{value: "abcde\nfg"}, 3)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["ab", "cd", "e", "fg"]
    end

    test "empty lines preserved" do
      lines = Input.render(%Input{value: "a\n\nb"}, 80)
      assert Enum.map(content_lines(lines), &strip_ansi/1) == ["a", "", "b"]
    end
  end

  describe "multiline cursor_rc/2" do
    test "cursor on second logical line" do
      # "hello\nworld", cursor at 'r' (grapheme 8) → row 2 (after border), col 2
      assert {2, 2} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 8}, 80)
    end

    test "cursor at start of second line" do
      assert {2, 0} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 6}, 80)
    end

    test "cursor on newline character itself" do
      # cursor at grapheme 5 (the \n) → row 1, col 5
      assert {1, 5} = Input.cursor_rc(%Input{value: "hello\nworld", cursor: 5}, 80)
    end

    test "cursor after wrapping + newline" do
      # "abcde\nfg" at width 3, lw=2: "ab" "cd" "e" "fg"
      # cursor at 'f' = grapheme 6 → row 3 (0-indexed) + 1 border = row 4
      assert {4, 0} = Input.cursor_rc(%Input{value: "abcde\nfg", cursor: 6}, 3)
    end
  end

  describe "vertical navigation — Up/Down" do
    test "down arrow moves to next visual line" do
      input = %Input{value: "hello\nworld", cursor: 2, width: 80}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "up arrow moves to previous visual line" do
      input = %Input{value: "hello\nworld", cursor: 8, width: 80}
      input = press(input, key(:up))
      assert input.cursor == 2
    end

    test "down clamps to shorter line" do
      input = %Input{value: "hello\nab", cursor: 4, width: 80}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "up at first visual line is no-op" do
      input = %Input{value: "hello\nworld", cursor: 2, width: 80}
      input = press(input, key(:up))
      assert input.cursor == 2
    end

    test "down at last visual line is no-op" do
      input = %Input{value: "hello\nworld", cursor: 8, width: 80}
      input = press(input, key(:down))
      assert input.cursor == 8
    end

    test "down navigates through wrapped lines" do
      # "abcde" at width 3, lw=2: "ab" "cd" "e". Cursor 1 (col 1) → row 1 col 1 = 'd' (pos 3)
      input = %Input{value: "abcde", cursor: 1, width: 3}
      input = press(input, key(:down))
      assert input.cursor == 3
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
      input = press(%Input{value: "hello\nworld", cursor: 2}, ctrl(?k))
      assert input.value == "he\nworld"
    end

    test "Ctrl+K at end of line kills the newline" do
      input = press(%Input{value: "hello\nworld", cursor: 5}, ctrl(?k))
      assert input.value == "helloworld"
    end

    test "Ctrl+U kills to start of current logical line" do
      input = press(%Input{value: "hello\nworld", cursor: 8}, ctrl(?u))
      assert input.value == "hello\nrld"
    end

    test "Ctrl+A moves to start of current logical line" do
      input = press(%Input{value: "hello\nworld", cursor: 8}, ctrl(?a))
      assert input.cursor == 6
    end

    test "Ctrl+E moves to end of current logical line" do
      input = press(%Input{value: "hello\nworld", cursor: 6}, ctrl(?e))
      assert input.cursor == 11
    end

    test "Home moves to start of current logical line" do
      input = press(%Input{value: "hello\nworld", cursor: 8}, key(:home))
      assert input.cursor == 6
    end

    test "End moves to end of current logical line" do
      input = press(%Input{value: "hello\nworld", cursor: 6}, key(:end))
      assert input.cursor == 11
    end
  end

  describe "backspace at line boundary" do
    test "backspace at start of second line merges lines" do
      input = press(%Input{value: "hello\nworld", cursor: 6}, key(:backspace))
      assert input.value == "helloworld"
      assert input.cursor == 5
    end
  end

  describe "multiline paste" do
    test "paste preserves newlines" do
      input = Input.paste(%Input{}, "hello\nworld")
      assert input.value == "hello\nworld"
      assert input.cursor == 11
    end

    test "paste normalizes \\r\\n to \\n" do
      input = Input.paste(%Input{}, "hello\r\nworld")
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

  # ── Scroll indicators (ported from upstream editor.ts) ─────────

  describe "scroll indicators" do
    test "no indicators when content fits within max visible lines" do
      input = %Input{value: "hello\nworld", height: 24}
      lines = Input.render(input, 40)
      assert hd(lines) == border(40)
      assert List.last(lines) == border(40)
      assert length(content_lines(lines)) == 2
    end

    test "shows down indicator when content exceeds viewport" do
      # height=20 → max_visible = max(5, div(20*3,10)) = 6
      text = Enum.map_join(1..10, "\n", &"line#{&1}")
      input = %Input{value: text, cursor: 0, height: 20}
      lines = Input.render(input, 40)

      # Cursor at top → no up indicator
      assert hd(lines) == border(40)
      # More content below → down indicator
      bottom = List.last(lines)
      assert bottom =~ "↓"
      assert bottom =~ "more"
    end

    test "shows up indicator when scrolled down" do
      text = Enum.map_join(1..10, "\n", &"line#{&1}")
      # Cursor at end → scrolled down
      input = %Input{value: text, cursor: String.length(text), height: 20}
      input = Input.update_scroll(input, 40)
      lines = Input.render(input, 40)

      top = hd(lines)
      assert top =~ "↑"
      assert top =~ "more"
    end

    test "shows both indicators when scrolled to middle" do
      text = Enum.map_join(1..20, "\n", &"line#{&1}")
      # Place cursor in the middle
      mid = String.length(Enum.map_join(1..10, "\n", &"line#{&1}"))
      input = %Input{value: text, cursor: mid, height: 20}
      input = Input.update_scroll(input, 40)
      lines = Input.render(input, 40)

      assert hd(lines) =~ "↑"
      assert List.last(lines) =~ "↓"
    end

    test "indicator shows correct line count" do
      # 10 content lines, max_visible=6 (height=20), cursor at top
      text = Enum.map_join(1..10, "\n", &"line#{&1}")
      input = %Input{value: text, cursor: 0, height: 20}
      lines = Input.render(input, 40)

      bottom = List.last(lines)
      assert bottom =~ "4 more"
    end

    test "scroll follows cursor downward" do
      text = Enum.map_join(1..10, "\n", &"line#{&1}")
      input = %Input{value: text, cursor: String.length(text), height: 20}
      input = Input.update_scroll(input, 40)
      lines = Input.render(input, 40)

      # Should show last 6 lines with cursor visible
      content = content_lines(lines)
      assert Enum.any?(content, &(&1 =~ "line10"))
    end

    test "cursor_rc accounts for scroll offset" do
      text = Enum.map_join(1..10, "\n", &"line#{&1}")
      input = %Input{value: text, cursor: String.length(text), height: 20}
      input = Input.update_scroll(input, 40)
      {row, _col} = Input.cursor_rc(input, 40)
      # max_visible=6, cursor should be within rendered range (+1 for border)
      assert row >= 1
      assert row <= 7
    end

    test "no indicators for short content regardless of height" do
      input = %Input{value: "short", height: 10}
      lines = Input.render(input, 40)
      assert length(lines) == 3
      assert hd(lines) == border(40)
      assert List.last(lines) == border(40)
    end
  end

  # ── Grapheme-aware wrapping render (ported from upstream editor.test.ts) ──

  describe "grapheme-aware wrapping render" do
    test "wraps emoji content to correct number of lines" do
      # ✅ is 2 columns wide. 6 emojis = 12 columns at width 10 → 2 content lines
      input = %Input{value: "✅✅✅✅✅✅"}
      lines = Input.render(input, 10)
      assert length(content_lines(lines)) == 2
    end

    test "CJK characters split at correct boundary" do
      # 日本語テスト = 6 CJK = 12 cols. width=10, lw=9:
      # 日(2)+本(4)+語(6)+テ(8)+ス(10>9 wraps) → ["日本語テ", "スト"]
      input = %Input{value: "日本語テスト"}
      lines = Input.render(input, 10)
      content = Enum.map(content_lines(lines), &strip_ansi/1)
      assert length(content) == 2
      assert hd(content) == "日本語テ"
      assert List.last(content) == "スト"
    end

    test "mixed ASCII and wide characters fit in single line" do
      # "Test ✅ OK 日本" = 15 display columns, width=16 (lw=15) to fit
      input = %Input{value: "Test ✅ OK 日本"}
      lines = Input.render(input, 16)
      assert length(content_lines(lines)) == 1
    end

    test "emoji at wrap boundary does not exceed width" do
      # "0123456789✅" = 10 ASCII + 2 emoji = 12 cols, width 11
      # Emoji wraps because 10+2 > 11
      input = %Input{value: "0123456789✅"}
      lines = Input.render(input, 11)
      content = Enum.map(content_lines(lines), &strip_ansi/1)
      assert length(content) == 2
      assert hd(content) == "0123456789"
      assert List.last(content) == "✅"
    end

    test "single word that fits exactly at width" do
      # width=10, lw=9: "1234567890" (10 chars) wraps last char
      input = %Input{value: "1234567890"}
      lines = Input.render(input, 10)
      assert length(lines) == 4
      assert strip_ansi(Enum.at(content_lines(lines), 0)) == "123456789"
      assert strip_ansi(Enum.at(content_lines(lines), 1)) == "0"
    end

    test "empty input renders border + empty + border" do
      lines = Input.render(%Input{value: ""}, 40)
      assert length(lines) == 3
      assert hd(lines) == border(40)
      # Empty input shows cursor as reverse-video space
      assert Enum.at(lines, 1) =~ "\e[7m \e[27m"
      assert List.last(lines) == border(40)
    end
  end

  # ── paddingX (ported from upstream editor.test.ts line 696-714) ──

  describe "paddingX" do
    test "layout_width reserves cursor column when paddingX=0" do
      # "aaaaaaaaa" = 9 chars at width=10 (lw=9) fits on 1 line
      input = %Input{value: "aaaaaaaaa", padding_x: 0}
      lines = Input.render(input, 10)
      assert length(content_lines(lines)) == 1

      # 10th char wraps
      input = %Input{value: "aaaaaaaaaa", padding_x: 0}
      lines = Input.render(input, 10)
      assert length(content_lines(lines)) == 2
    end

    test "layout_width uses full contentWidth when paddingX>0" do
      # paddingX=1, width=12: contentWidth = 12 - 2 = 10, layoutWidth = 10
      # 10 chars should fit on 1 line
      input = %Input{value: "aaaaaaaaaa", padding_x: 1}
      lines = Input.render(input, 12)
      assert length(content_lines(lines)) == 1

      # 11th char wraps
      input = %Input{value: "aaaaaaaaaaa", padding_x: 1}
      lines = Input.render(input, 12)
      assert length(content_lines(lines)) == 2
    end

    test "wrap boundary matches for paddingX=0 and paddingX=1" do
      # Upstream test: for both paddingX values, 9 chars fit on 1 line,
      # 10 chars wrap to 2 lines (layoutWidth=9 in both cases)
      for px <- [0, 1] do
        effective_width = 10 + px
        input = %Input{value: String.duplicate("a", 9), padding_x: px}
        lines = Input.render(input, effective_width)
        assert length(content_lines(lines)) == 1, "px=#{px}: 9 chars should fit"

        input = %Input{value: String.duplicate("a", 10), padding_x: px}
        lines = Input.render(input, effective_width)
        assert length(content_lines(lines)) == 2, "px=#{px}: 10 chars should wrap"
      end
    end

    test "content lines are padded with spaces when paddingX>0" do
      input = %Input{value: "hello", padding_x: 2}
      lines = Input.render(input, 20)
      content = content_lines(lines)
      line = hd(content)
      assert String.starts_with?(line, "  ")
      assert String.ends_with?(line, "  ")
    end

    test "no padding applied when paddingX=0" do
      input = %Input{value: "hello", padding_x: 0}
      lines = Input.render(input, 20)
      content = content_lines(lines)
      line = strip_ansi(hd(content))
      assert String.starts_with?(line, "h")
    end

    test "cursor_rc includes padding offset" do
      # paddingX=2, width=20: cursor at col 0 → display col 2
      input = %Input{value: "hello", cursor: 0, padding_x: 2}
      {row, col} = Input.cursor_rc(input, 20)
      assert row == 1
      assert col == 2

      # cursor at 3 → display col 5
      input = %Input{value: "hello", cursor: 3, padding_x: 2}
      {_row, col} = Input.cursor_rc(input, 20)
      assert col == 5
    end

    test "paddingX clamped to half width" do
      # width=5, maxPadding=2: paddingX=10 → clamped to 2
      input = %Input{value: "ab", padding_x: 10}
      lines = Input.render(input, 5)
      content = content_lines(lines)
      line = hd(content)
      assert String.starts_with?(line, "  ")
    end

    test "single word fits exactly at width with paddingX=1" do
      # width=11 (10 + 1 for padding on each side), px=1
      # contentWidth = 11 - 2 = 9, layoutWidth = 9 (no cursor col subtracted)
      # But we said +1 padding each side = need width=12 for 10 content cols
      # Let's use width=12, px=1: contentWidth=10, layoutWidth=10
      input = %Input{value: "1234567890", padding_x: 1}
      lines = Input.render(input, 12)
      assert length(content_lines(lines)) == 1
      line = strip_ansi(hd(content_lines(lines)))
      assert line =~ "1234567890"
    end
  end

  # ── CJK / fullwidth overflow invariant (upstream input.test.ts) ──

  describe "wide-character overflow invariant" do
    alias OctoPi.TUI.WrapAnsi

    test "CJK and fullwidth text never overflows terminal width at any cursor position" do
      cases = [
        "가나다라마바사아자차카타파하 한글 텍스트가 터미널 너비를 초과하면 크래시가 발생합니다 이것은 재현용 테스트입니다",
        "これはテスト文章です。日本語のテキストが正しく表示されるかどうかを確認するためのサンプルテキストです。あいうえお",
        "这是一段测试文本，用于验证中文字符在终端中的显示宽度是否被正确计算，如果不正确就会导致用户界面崩溃的问题",
        "ＡＢＣＤＥＦＧＨＩＪＫＬＭＮＯＰＱＲＳＴＵＶＷＸＹＺ０１２３４５６７８９ａｂｃｄｅｆｇｈｉｊｋｌｍ"
      ]

      width = 93

      cursor_positions = [
        {"start", fn input -> input end},
        {"middle",
         fn input ->
           Enum.reduce(1..10, input, fn _, s -> press(s, key(:right)) end)
         end},
        {"end", fn input -> press(input, ctrl(?e)) end}
      ]

      for text <- cases, {label, move} <- cursor_positions do
        input =
          %Input{}
          |> Input.set_value(text)
          |> move.()

        lines = Input.render(input, width)

        for line <- lines do
          assert WrapAnsi.visible_width(line) <= width,
                 "rendered line overflowed at cursor #{label} for #{text}: #{inspect(line)}"
        end
      end
    end

    test "cursor stays visible during horizontal scroll with wide text" do
      width = 20
      text = "가나다라마바사아자차카타파하"

      input =
        %Input{}
        |> Input.set_value(text)
        |> press(ctrl(?a))
        |> move_right(5)
        |> Input.update_scroll(width)

      lines = Input.render(input, width)

      for line <- lines do
        assert WrapAnsi.visible_width(line) <= width
      end
    end
  end

  # ── handle_key/3 — keybindings dispatch (opi-0g4.17) ──────────

  describe "handle_key/3 — keybindings-based dispatch" do
    alias OctoPi.TUI.Keybindings

    defp press3(input, key_spec, kb) do
      case Input.handle_key(input, key_spec, kb) do
        {new_input, _events} -> new_input
        new_input -> new_input
      end
    end

    test "handle_key/2 compatibility shim still works (default keybindings)" do
      input = type(%Input{}, "hello")
      result = press(input, key(:left))
      assert result.cursor == 4
    end

    test "handle_key/3 with nil keybindings uses defaults" do
      input = type(%Input{}, "hello")
      result = press3(input, key(:left), nil)
      assert result.cursor == 4
    end

    test "custom binding for tui.input.submit submits on remapped key" do
      kb = Keybindings.new(%{"tui.input.submit" => "ctrl+m"})
      input = type(%Input{}, "hello")
      result = Input.handle_key(input, ctrl(?m), kb)
      assert {_, [{:submit, "hello"}]} = result
    end

    test "default submit key (enter) no longer works when tui.input.submit is remapped" do
      kb = Keybindings.new(%{"tui.input.submit" => "ctrl+m"})
      input = type(%Input{}, "hello")
      result = Input.handle_key(input, key(:enter), kb)
      refute match?({_, [{:submit, _}]}, result)
    end

    test "custom binding for tui.editor.cursorLeft moves cursor on remapped key" do
      kb = Keybindings.new(%{"tui.editor.cursorLeft" => "ctrl+j"})
      input = type(%Input{}, "hello")
      result = press3(input, %Key{key: ?j, modifiers: [:ctrl]}, kb)
      assert result.cursor == 4
    end

    test "default cursor left (left arrow) no longer works when remapped" do
      kb = Keybindings.new(%{"tui.editor.cursorLeft" => "ctrl+j"})
      input = type(%Input{}, "hello")
      result = press3(input, key(:left), kb)
      assert result.cursor == 5
    end

    test "alt+left triggers cursorWordLeft with default keybindings" do
      kb = Keybindings.new()
      input = type(%Input{}, "hello world")
      result = press3(input, %Key{key: :left, modifiers: [:alt]}, kb)
      assert result.cursor == 6
    end

    test "alt+backspace triggers deleteWordBackward with default keybindings" do
      kb = Keybindings.new()
      input = type(%Input{}, "hello world")
      result = press3(input, %Key{key: :backspace, modifiers: [:alt]}, kb)
      assert result.value == "hello "
    end

    test "tui.editor.undo action triggered via keybindings" do
      kb = Keybindings.new(%{"tui.editor.undo" => "ctrl+z"})
      input = type(%Input{}, "hello")
      result = press3(input, ctrl(?z), kb)
      assert result.value == ""
    end
  end

  describe "slash-command autocomplete — popup and submit" do
    alias OctoPi.TUI.Autocomplete
    alias OctoPi.TUI.Autocomplete.SlashCommandProvider

    defp with_slash_provider do
      provider = SlashCommandProvider.new(Autocomplete.builtin_commands())
      %Input{autocomplete_provider: provider}
    end

    test "typing / triggers autocomplete with all builtin commands" do
      s = Input.insert(with_slash_provider(), "/")
      assert s.autocomplete_active
      assert length(s.autocomplete_suggestions) == length(Autocomplete.builtin_commands())
    end

    test "typing /h narrows suggestions to commands starting with h" do
      s = with_slash_provider() |> Input.insert("/") |> Input.insert("h")
      assert s.autocomplete_active
      assert Enum.all?(s.autocomplete_suggestions, &String.starts_with?(&1.value, "/h"))
    end

    test "render_dropdown returns non-empty lines when autocomplete is active" do
      s = Input.insert(with_slash_provider(), "/")
      lines = Input.render_dropdown(s, 80)
      assert lines != []
    end

    test "render_dropdown returns empty list when autocomplete is inactive" do
      s = %Input{value: "hello", autocomplete_active: false}
      assert Input.render_dropdown(s, 80) == []
    end

    test "Enter while autocomplete is active accepts suggestion AND emits submit" do
      s = with_slash_provider() |> Input.insert("/") |> Input.insert("h")
      assert s.autocomplete_active
      assert {new_input, [{:submit, value}]} = Input.handle_key(s, key(:enter))
      refute new_input.autocomplete_active
      assert String.starts_with?(value, "/")
    end

    test "Tab while autocomplete is active accepts suggestion without submitting" do
      s = with_slash_provider() |> Input.insert("/") |> Input.insert("h")
      result = Input.handle_key(s, key(:tab))
      refute match?({_, [{:submit, _}]}, result)

      case result do
        {new_input, _} -> refute new_input.autocomplete_active
        new_input -> refute new_input.autocomplete_active
      end
    end

    test "Up/Down navigate suggestions" do
      s = Input.insert(with_slash_provider(), "/")
      s_down = press(s, key(:down))
      assert s_down.autocomplete_selected == 1
      s_up = press(s_down, key(:up))
      assert s_up.autocomplete_selected == 0
    end

    test "backspace while active deletes char and re-queries suggestions" do
      s = with_slash_provider() |> Input.insert("/") |> Input.insert("h")
      assert Enum.all?(s.autocomplete_suggestions, &String.starts_with?(&1.value, "/h"))

      s2 = press(s, key(:backspace))
      assert s2.value == "/"
      assert s2.autocomplete_active
      assert length(s2.autocomplete_suggestions) == length(Autocomplete.builtin_commands())
    end

    test "backspace clears autocomplete when value no longer starts with /" do
      s = Input.insert(with_slash_provider(), "/")
      assert s.autocomplete_active

      s2 = press(s, key(:backspace))
      assert s2.value == ""
      refute s2.autocomplete_active
    end
  end
end
