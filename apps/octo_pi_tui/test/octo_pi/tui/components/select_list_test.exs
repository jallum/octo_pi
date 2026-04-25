defmodule OctoPi.TUI.Components.SelectListTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SelectList
  alias OctoPi.TUI.Components.SelectList.Item
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.WrapAnsi

  defp visible_index_of(line, needle) do
    case String.split(line, needle, parts: 2) do
      [before, _] -> WrapAnsi.visible_width(before)
      _ -> nil
    end
  end

  describe "render/2" do
    test "renders each item on its own line" do
      lines = SelectList.render(%SelectList{items: ["a", "b", "c"]}, 80)
      assert length(lines) == 3
    end

    test "marks the selected item with reverse-video prefix" do
      [l0, l1, _] = SelectList.render(%SelectList{items: ["a", "b", "c"], selected: 0}, 80)
      assert l0 =~ "\e[7m"
      refute l1 =~ "\e[7m"
    end

    test "empty list shows a sentinel" do
      assert ["(empty)"] = SelectList.render(%SelectList{items: []}, 80)
    end
  end

  describe "handle_key/2" do
    test "down moves selection forward" do
      s = %SelectList{items: ["a", "b", "c"], selected: 0}
      assert %SelectList{selected: 1} = SelectList.handle_key(s, %Key{key: :down})
    end

    test "down wraps at end" do
      s = %SelectList{items: ["a", "b", "c"], selected: 2}
      assert %SelectList{selected: 0} = SelectList.handle_key(s, %Key{key: :down})
    end

    test "up moves selection backward" do
      s = %SelectList{items: ["a", "b", "c"], selected: 2}
      assert %SelectList{selected: 1} = SelectList.handle_key(s, %Key{key: :up})
    end

    test "up wraps at start" do
      s = %SelectList{items: ["a", "b", "c"], selected: 0}
      assert %SelectList{selected: 2} = SelectList.handle_key(s, %Key{key: :up})
    end

    test "Enter yields {:select, item}" do
      s = %SelectList{items: ["a", "b", "c"], selected: 1}
      assert {_, [{:select, "b"}]} = SelectList.handle_key(s, %Key{key: :enter})
    end

    test "Escape yields :cancel" do
      s = %SelectList{items: ["a"], selected: 0}
      assert {_, [:cancel]} = SelectList.handle_key(s, %Key{key: :escape})
    end

    test "empty list is a no-op for all keys" do
      s = %SelectList{items: []}
      assert ^s = SelectList.handle_key(s, %Key{key: :up})
      assert ^s = SelectList.handle_key(s, %Key{key: :enter})
    end
  end

  # --- upstream select-list.test.ts parity ---

  describe "two-column render (upstream parity)" do
    test "normalizes multiline descriptions to single line" do
      item = %Item{value: "test", label: "test", description: "Line one\nLine two\nLine three"}
      [line | _] = SelectList.render(%SelectList{items: [item], selected: 0}, 100)
      refute String.contains?(line, "\n")
      assert String.contains?(line, "Line one Line two Line three")
    end

    test "descriptions align even when primary text is truncated" do
      items = [
        %Item{value: "short", label: "short", description: "short description"},
        %Item{
          value: "very-long-command-name-that-needs-truncation",
          label: "very-long-command-name-that-needs-truncation",
          description: "long description"
        }
      ]

      [row0, row1] = SelectList.render(%SelectList{items: items, selected: 5}, 80)

      assert visible_index_of(row0, "short description") ==
               visible_index_of(row1, "long description")
    end

    test "minimum primary column width" do
      items = [
        %Item{value: "a", label: "a", description: "first"},
        %Item{value: "bb", label: "bb", description: "second"}
      ]

      state = %SelectList{
        items: items,
        selected: 5,
        min_primary_column_width: 12,
        max_primary_column_width: 20
      }

      [row0, row1] = SelectList.render(state, 80)
      assert visible_index_of(row0, "first") == 14
      assert visible_index_of(row1, "second") == 14
    end

    test "maximum primary column width truncates long labels" do
      items = [
        %Item{
          value: "very-long-command-name-that-needs-truncation",
          label: "very-long-command-name-that-needs-truncation",
          description: "first"
        },
        %Item{value: "short", label: "short", description: "second"}
      ]

      state = %SelectList{
        items: items,
        selected: 5,
        min_primary_column_width: 12,
        max_primary_column_width: 20
      }

      [row0, row1] = SelectList.render(state, 80)
      assert visible_index_of(row0, "first") == 22
      assert visible_index_of(row1, "second") == 22
    end

    test "custom truncate_primary preserves description alignment" do
      items = [
        %Item{
          value: "very-long-command-name-that-needs-truncation",
          label: "very-long-command-name-that-needs-truncation",
          description: "first"
        },
        %Item{value: "short", label: "short", description: "second"}
      ]

      truncate = fn %{text: t, max_width: m} ->
        if String.length(t) <= m, do: t, else: String.slice(t, 0, max(0, m - 1)) <> "…"
      end

      state = %SelectList{
        items: items,
        selected: 5,
        min_primary_column_width: 12,
        max_primary_column_width: 12,
        truncate_primary: truncate
      }

      [row0, row1] = SelectList.render(state, 80)
      assert String.contains?(row0, "…")
      assert visible_index_of(row0, "first") == visible_index_of(row1, "second")
    end
  end
end
