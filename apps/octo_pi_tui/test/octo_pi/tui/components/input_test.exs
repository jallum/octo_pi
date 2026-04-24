defmodule OctoPi.TUI.Components.InputTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Input
  alias OctoPi.TUI.Key

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

    # The cursor is painted by the terminal itself — Interactive
    # emits a CSI H positioning command after the renderer flush
    # so the hardware cursor lands at the right spot. Input.render
    # intentionally doesn't paint its own marker (avoids the
    # double-cursor artifact).
  end

  describe "handle_key/2 — cursor movement" do
    test "left moves cursor one grapheme back" do
      s = %Input{value: "abc", cursor: 2}
      assert %Input{cursor: 1} = Input.handle_key(s, %Key{key: :left})
    end

    test "left at 0 stays at 0" do
      assert %Input{cursor: 0} =
               Input.handle_key(%Input{value: "abc", cursor: 0}, %Key{key: :left})
    end

    test "right moves cursor one grapheme forward" do
      s = %Input{value: "abc", cursor: 1}
      assert %Input{cursor: 2} = Input.handle_key(s, %Key{key: :right})
    end

    test "right at end stays at end" do
      s = %Input{value: "abc", cursor: 3}
      assert %Input{cursor: 3} = Input.handle_key(s, %Key{key: :right})
    end

    test "Ctrl+A moves cursor to start" do
      s = %Input{value: "abc", cursor: 2}
      ctrl_a = %Key{key: ?a, modifiers: [:ctrl]}
      assert %Input{cursor: 0} = Input.handle_key(s, ctrl_a)
    end

    test "Ctrl+E moves cursor to end" do
      s = %Input{value: "abcde", cursor: 1}
      ctrl_e = %Key{key: ?e, modifiers: [:ctrl]}
      assert %Input{cursor: 5} = Input.handle_key(s, ctrl_e)
    end

    test ":home moves to start, :end to end" do
      s = %Input{value: "xyz", cursor: 1}
      assert %Input{cursor: 0} = Input.handle_key(s, %Key{key: :home})
      assert %Input{cursor: 3} = Input.handle_key(s, %Key{key: :end})
    end
  end

  describe "handle_key/2 — editing" do
    test "backspace deletes grapheme before cursor" do
      s = %Input{value: "abc", cursor: 3}
      assert %Input{value: "ab", cursor: 2} = Input.handle_key(s, %Key{key: :backspace})
    end

    test "backspace at cursor 0 is no-op" do
      s = %Input{value: "abc", cursor: 0}
      assert %Input{value: "abc", cursor: 0} = Input.handle_key(s, %Key{key: :backspace})
    end

    test "backspace handles CJK correctly (grapheme-aware)" do
      s = %Input{value: "日本語", cursor: 2}
      assert %Input{value: "日語", cursor: 1} = Input.handle_key(s, %Key{key: :backspace})
    end

    test "delete removes grapheme at cursor" do
      s = %Input{value: "abc", cursor: 1}
      assert %Input{value: "ac", cursor: 1} = Input.handle_key(s, %Key{key: :delete})
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

    test "insert respects focused=false (no-op)" do
      s = %Input{value: "abc", cursor: 1, focused: false}
      assert %Input{value: "abc", cursor: 1} = Input.insert(s, "X")
    end
  end

  describe "handle_key/2 — submit" do
    test "Enter yields {:submit, value} event" do
      s = %Input{value: "hi", cursor: 2}
      assert {%Input{}, [{:submit, "hi"}]} = Input.handle_key(s, %Key{key: :enter})
    end

    test "Escape yields :cancel event" do
      s = %Input{value: "hi"}
      assert {%Input{}, [:cancel]} = Input.handle_key(s, %Key{key: :escape})
    end
  end

  describe "handle_key/2 — unfocused" do
    test "any key is a no-op when unfocused" do
      s = %Input{value: "hi", focused: false}
      assert ^s = Input.handle_key(s, %Key{key: :enter})
      assert ^s = Input.handle_key(s, %Key{key: :left})
    end
  end
end
