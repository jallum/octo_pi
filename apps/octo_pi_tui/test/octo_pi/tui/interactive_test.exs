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

  describe "run/1 end-to-end" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Event, as: AIEvent
    alias OctoPi.AI.Model
    alias OctoPi.TUI.Terminal, as: TUITerminal

    setup do
      on_exit(&FakeTransport.clear/0)
      :ok
    end

    defp model do
      %Model{
        id: "fake-model",
        name: "fake",
        api: :fake_api,
        provider: :fake,
        base_url: "http://fake",
        context_window: 100,
        max_tokens: 100
      }
    end

    defp assistant_msg(text, stop_reason \\ :stop) do
      %Assistant{
        api: :fake_api,
        provider: :fake,
        model: "fake-model",
        timestamp: 0,
        content: [%Content.Text{text: text}],
        stop_reason: stop_reason,
        usage: %OctoPi.AI.Usage{}
      }
    end

    test "types a prompt, receives response, then exits on Ctrl+C" do
      final = assistant_msg("pong")

      FakeTransport.set_script([
        [
          %AIEvent.Start{partial: %{final | content: [], stop_reason: nil}},
          %AIEvent.TextDelta{content_index: 0, delta: "pong", partial: final},
          %AIEvent.Done{reason: :stop, message: final}
        ]
      ])

      parent = self()

      # write_fn sends every rendered chunk to both a buffer and
      # the test pid, so we can synchronize via `assert_receive`
      # on specific payloads without polling.
      {:ok, buffer} = Agent.start_link(fn -> [] end)

      write_fn = fn bytes ->
        bin = IO.iodata_to_binary(bytes)
        Agent.update(buffer, &[bin | &1])
        send(parent, {:tui_output, bin})
      end

      terminal_name = :"test_terminal_#{System.unique_integer([:positive])}"

      runner =
        Task.async(fn ->
          result =
            Interactive.run(
              model: model(),
              transport: FakeTransport,
              tools: [],
              write_fn: write_fn,
              skip_raw_mode: true,
              skip_sigwinch: true,
              auto_start_reader: false,
              dimensions: {80, 24},
              terminal_name: terminal_name
            )

          send(parent, {:run_done, result})
        end)

      # Initial render lands first; wait for it before feeding input.
      assert_receive {:tui_output, _initial}, 2_000

      # Feed the prompt + Enter.
      :ok = TUITerminal.feed_chunk(terminal_name, "hi")
      :ok = TUITerminal.feed_chunk(terminal_name, "\r")

      # Drain tui_output messages until one contains "pong" (the
      # agent's streamed response). receive_until is defined below.
      receive_until_containing("pong", 2_000)

      # Ctrl+C exits.
      :ok = TUITerminal.feed_chunk(terminal_name, <<0x03>>)
      assert_receive {:run_done, :ok}, 2_000

      Task.await(runner, 1_000)

      all = Agent.get(buffer, & &1) |> Enum.reverse() |> IO.iodata_to_binary()
      assert all =~ "hi"
      assert all =~ "pong"
    end

    defp receive_until_containing(needle, timeout) do
      receive do
        {:tui_output, bin} ->
          if String.contains?(bin, needle),
            do: :ok,
            else: receive_until_containing(needle, timeout)
      after
        timeout -> flunk("did not see #{inspect(needle)} in any tui_output")
      end
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
