defmodule OctoPi.TUI.Components.UserMessageSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.UserMessageSelector
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  defp key(k), do: %Key{key: k}

  defp press(sel, k) do
    case UserMessageSelector.handle_key(sel, k) do
      {new, _events} -> new
      new -> new
    end
  end

  defp test_messages do
    [
      %{id: "u1", text: "What is the capital of France?"},
      %{id: "u2", text: "How do I sort a list in Python?"},
      %{id: "u3", text: "Explain monads"}
    ]
  end

  describe "new/2" do
    test "starts with last message selected" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      assert sel.selected == 2
    end

    test "empty messages list" do
      sel = UserMessageSelector.new([], @theme)
      assert sel.messages == []
    end
  end

  describe "navigation" do
    test "Up moves selection backward" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      sel = press(sel, key(:up))
      assert sel.selected == 1
    end

    test "Down wraps from last to first" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      sel = press(sel, key(:down))
      assert sel.selected == 0
    end

    test "Up wraps from first to last" do
      sel = %{UserMessageSelector.new(test_messages(), @theme) | selected: 0}
      sel = press(sel, key(:up))
      assert sel.selected == 2
    end
  end

  describe "selection" do
    test "Enter emits fork_at event with selected message" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      {_sel, events} = UserMessageSelector.handle_key(sel, key(:enter))
      assert [{:fork_at, msg}] = events
      assert msg.id == "u3"
    end

    test "Escape emits cancel" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      {_sel, events} = UserMessageSelector.handle_key(sel, key(:escape))
      assert [:cancel] = events
    end

    test "Enter on empty list emits cancel" do
      sel = UserMessageSelector.new([], @theme)
      {_sel, events} = UserMessageSelector.handle_key(sel, key(:enter))
      assert [:cancel] = events
    end
  end

  describe "render/2" do
    test "shows message text" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      lines = sel |> UserMessageSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "capital of France"))
    end

    test "shows metadata line with position" do
      sel = UserMessageSelector.new(test_messages(), @theme)
      lines = sel |> UserMessageSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "Message"))
    end

    test "renders empty state for no messages" do
      sel = UserMessageSelector.new([], @theme)
      lines = sel |> UserMessageSelector.render(80) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "No user messages"))
    end
  end
end
