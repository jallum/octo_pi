defmodule OctoPi.TUI.InteractiveTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.TUI.Components.Input
  alias OctoPi.TUI.{Interactive, Key}

  describe "handle_event — keyboard input" do
    test "printable char is inserted into the Input" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, {:char, "h"})
      assert s.input.value == "h"
      assert s.input.cursor == 1
    end

    test "Ctrl+C sets exit = true" do
      s = %Interactive{}
      s = Interactive.handle_event(s, {:key, %Key{key: ?c, modifiers: [:ctrl]}})
      assert s.exit
    end

    test "left arrow routes to Input cursor movement" do
      s = %Interactive{input: %Input{value: "abc", cursor: 2}}
      s = Interactive.handle_event(s, {:key, %Key{key: :left}})
      assert s.input.cursor == 1
    end

    test "Enter with empty input is a no-op" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, {:key, %Key{key: :enter}})
      assert s.input.value == ""
      assert s.transcript == []
    end

    test "Enter with non-empty input appends user message + clears input" do
      s = %Interactive{input: %Input{value: "hi", cursor: 2}, session: nil}
      s = Interactive.handle_event(s, {:key, %Key{key: :enter}})
      assert s.transcript == [{:user, "hi"}]
      assert s.input.value == ""
      assert s.input.cursor == 0
    end
  end

  describe "handle_event — agent events" do
    test "MessageUpdate appends a streaming assistant entry" do
      s = %Interactive{}

      partial = %Assistant{
        content: [%Content.Text{text: "hello"}],
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0
      }

      s =
        Interactive.handle_event(
          s,
          {:octo_pi_agent_event, %Event.MessageUpdate{partial: partial}}
        )

      assert s.transcript == [{:assistant, "hello", :streaming}]
    end

    test "subsequent MessageUpdates replace the streaming entry's text" do
      s = %Interactive{transcript: [{:assistant, "he", :streaming}]}

      partial = %Assistant{
        content: [%Content.Text{text: "hello"}],
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0
      }

      s =
        Interactive.handle_event(
          s,
          {:octo_pi_agent_event, %Event.MessageUpdate{partial: partial}}
        )

      assert s.transcript == [{:assistant, "hello", :streaming}]
    end

    test "MessageEnd finalizes the streaming entry" do
      s = %Interactive{transcript: [{:assistant, "hi", :streaming}]}

      msg = %Assistant{
        content: [%Content.Text{text: "hi"}],
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0,
        stop_reason: :stop
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})
      assert s.transcript == [{:assistant, "hi", :done}]
    end

    test "unrelated agent events don't modify the transcript" do
      s = %Interactive{transcript: [{:user, "x"}]}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert s.transcript == [{:user, "x"}]
    end
  end

  describe "handle_event — resize" do
    test "updates width + height" do
      s = %Interactive{width: 80, height: 24}
      s = Interactive.handle_event(s, {:resize, 100, 30})
      assert s.width == 100
      assert s.height == 30
    end
  end

  describe "render/1" do
    test "produces transcript lines + blank + input" do
      s = %Interactive{
        transcript: [{:user, "hi"}, {:assistant, "hello!", :done}],
        input: %Input{value: "next", cursor: 4, focused: true},
        width: 80
      }

      lines = Interactive.render(s)
      text = Enum.join(lines, "\n")

      assert text =~ "> hi"
      assert text =~ "hello!"
      assert text =~ "next"
    end
  end
end
