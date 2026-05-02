defmodule OctoPi.TUI.Components.PendingMessagesTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.PendingMessages
  alias OctoPi.TUI.Keybindings
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.VDOM
  alias OctoPi.TUI.WrapAnsi

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  def ctx(width \\ 80) do
    %RenderContext{theme: nil, width: width}
  end

  def kb_state(keybindings \\ %{}) do
    %Keybindings{bindings: keybindings, definitions: %{}, conflicts: []}
  end

  describe "render/2" do
    test "empty pending messages renders nothing" do
      state = %{pending_steering: [], pending_follow_up: [], keybindings: kb_state()}
      assert %VDOM.VLines{lines: []} = PendingMessages.render(state, ctx())
    end

    test "steering messages render with prefix" do
      state = %{pending_steering: ["focus on tests", "use elixir"], pending_follow_up: [], keybindings: kb_state()}
      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      assert Enum.any?(stripped, &String.starts_with?(&1, "Steering: focus on tests"))
      assert Enum.any?(stripped, &String.starts_with?(&1, "Steering: use elixir"))
    end

    test "follow-up messages render with prefix" do
      state = %{pending_steering: [], pending_follow_up: ["clarify API"], keybindings: kb_state()}
      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      assert Enum.any?(stripped, &String.starts_with?(&1, "Follow-up: clarify API"))
    end

    test "messages render in FIFO order (steering first, then follow-up)" do
      state = %{
        pending_steering: ["steer 1"],
        pending_follow_up: ["follow 1", "follow 2"],
        keybindings: kb_state()
      }

      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      assert Enum.find_index(stripped, &String.starts_with?(&1, "Steering: steer 1")) <
               Enum.find_index(stripped, &String.starts_with?(&1, "Follow-up: follow 1"))

      assert Enum.find_index(stripped, &String.starts_with?(&1, "Follow-up: follow 1")) <
               Enum.find_index(stripped, &String.starts_with?(&1, "Follow-up: follow 2"))
    end

    test "hint line appears at the end" do
      state = %{
        pending_steering: ["x"],
        pending_follow_up: [],
        keybindings: kb_state(%{"app.message.dequeue" => ["d"]})
      }

      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      assert List.last(stripped) =~ "edit all queued messages"
    end

    test "hint includes keybinding when available" do
      state = %{
        pending_steering: ["test"],
        pending_follow_up: [],
        keybindings: kb_state(%{"app.message.dequeue" => ["d"]})
      }

      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      hint_line = List.last(stripped)
      assert hint_line =~ "d to edit all queued messages"
    end

    test "hint falls back when no keybinding" do
      state = %{pending_steering: ["test"], pending_follow_up: [], keybindings: kb_state()}
      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      hint_line = List.last(stripped)
      assert hint_line =~ "to edit all queued messages"
    end

    test "lines are truncated at width" do
      long_text = String.duplicate("x", 100)
      state = %{pending_steering: [long_text], pending_follow_up: [], keybindings: kb_state()}
      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(40))
      stripped = Enum.map(lines, &strip_ansi/1)

      for line <- stripped do
        assert WrapAnsi.visible_width(line) <= 40
      end
    end

    test "lines fill to full width (no padding)" do
      state = %{pending_steering: ["short"], pending_follow_up: [], keybindings: kb_state()}
      %VDOM.VLines{lines: lines} = PendingMessages.render(state, ctx(80))
      stripped = Enum.map(lines, &strip_ansi/1)

      for line <- stripped do
        assert WrapAnsi.visible_width(line) == 80,
               "line should fill full width: #{inspect(line)}"
      end
    end
  end
end
