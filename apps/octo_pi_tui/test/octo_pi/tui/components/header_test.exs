defmodule OctoPi.TUI.Components.HeaderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.Header
  alias OctoPi.TUI.Key

  defp strip_ansi(str), do: String.replace(str, ~r/\e\[[0-9;]*m/, "")

  describe "render/2" do
    test "compact mode renders logo + single-line hints + onboarding" do
      lines = Header.render(%Header{expanded: false}, 80)
      text = Enum.map_join(lines, "\n", &strip_ansi/1)

      assert text =~ "OctoPi"
      assert text =~ "Ctrl+C"
      assert text =~ "?"
      assert text =~ "Press ? to show full startup help."
    end

    test "expanded mode renders multi-line hints" do
      lines = Header.render(%Header{expanded: true}, 80)
      text = Enum.map_join(lines, "\n", &strip_ansi/1)

      assert text =~ "Ctrl+C to interrupt"
      assert text =~ "Ctrl+L to clear"
      assert text =~ "for commands"
    end

    test "starts and ends with blank spacer line" do
      lines = Header.render(%Header{}, 80)
      assert hd(lines) == ""
      assert List.last(lines) == ""
    end

    test "logo includes version" do
      lines = Header.render(%Header{}, 80)
      text = Enum.map_join(lines, "\n", &strip_ansi/1)
      assert text =~ ~r/OctoPi v\d+\.\d+/
    end
  end

  describe "handle_key/2" do
    test "? toggles expanded" do
      s = %Header{expanded: false}
      s = Header.handle_key(s, %Key{key: ??, modifiers: []})
      assert s.expanded

      s = Header.handle_key(s, %Key{key: ??, modifiers: []})
      refute s.expanded
    end

    test "other keys are no-op" do
      s = %Header{expanded: false}
      assert s == Header.handle_key(s, %Key{key: ?x})
    end
  end
end
