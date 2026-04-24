defmodule OctoPi.TUI.InteractiveTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.TUI.Components.{AssistantMessage, Input, ToolExecution}
  alias OctoPi.TUI.{Interactive, Key, Theme}

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

    test "Escape clears non-empty input" do
      s = %Interactive{input: %Input{value: "draft", cursor: 5}}
      s = Interactive.handle_event(s, {:key, %Key{key: :escape}})
      assert s.input.value == ""
      assert s.input.cursor == 0
      refute s.exit
    end

    test "Escape with empty input exits (double-Escape pattern)" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, {:key, %Key{key: :escape}})
      assert s.exit
    end

    test "paste markers buffer chars and insert atomically" do
      s = %Interactive{input: %Input{value: "hello world", cursor: 5}}
      s = Interactive.handle_event(s, :paste_start)
      s = Interactive.handle_event(s, {:char, "b"})
      s = Interactive.handle_event(s, {:char, "o"})
      s = Interactive.handle_event(s, {:char, "o"})
      s = Interactive.handle_event(s, :paste_end)
      assert s.input.value == "helloboo world"
      assert s.paste_buffer == nil
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

      assert [%AssistantMessage{content: [text: "hello"]}] = s.transcript
    end

    test "subsequent MessageUpdates replace the streaming entry's text" do
      existing = AssistantMessage.new(nil, content: [text: "he"])
      s = %Interactive{transcript: [existing]}

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

      assert [%AssistantMessage{content: [text: "hello"]}] = s.transcript
    end

    test "MessageEnd finalizes the streaming entry" do
      existing = AssistantMessage.new(nil, content: [text: "hi"])
      s = %Interactive{transcript: [existing]}

      msg = %Assistant{
        content: [%Content.Text{text: "hi"}],
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0,
        stop_reason: :stop
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})
      assert [%AssistantMessage{content: [text: "hi"], stop_reason: nil}] = s.transcript
    end

    test "MessageEnd with tool calls sets has_tool_calls" do
      existing = AssistantMessage.new(nil, content: [text: "ok"])
      s = %Interactive{transcript: [existing]}

      msg = %Assistant{
        content: [%Content.Text{text: "ok"}, %OctoPi.AI.ToolCall{id: "tc1", name: "Read"}],
        api: :fake,
        provider: :fake,
        model: "m",
        timestamp: 0,
        stop_reason: :tool_use
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})
      assert [%AssistantMessage{has_tool_calls: true}] = s.transcript
    end

    test "ToolExecutionStart appends a ToolExecution component" do
      s = %Interactive{}

      ev = %Event.ToolExecutionStart{tool_call_id: "tc1", tool_name: "Read"}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, ev})

      assert [%ToolExecution{tool_name: "Read", tool_call_id: "tc1", status: :pending}] =
               s.transcript
    end

    test "ToolExecutionEnd sets result on matching ToolExecution" do
      te = ToolExecution.new("Bash", "tc2", %{}, nil)
      s = %Interactive{transcript: [te]}

      result = %OctoPi.Agent.Tool.Result{
        content: [%Content.Text{text: "output here"}],
        is_error?: false
      }

      ev = %Event.ToolExecutionEnd{tool_call_id: "tc2", tool_name: "Bash", result: result}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, ev})

      assert [%ToolExecution{status: :success, result: "output here"}] = s.transcript
    end

    test "ToolExecutionEnd with error sets error status" do
      te = ToolExecution.new("Bash", "tc3", %{}, nil)
      s = %Interactive{transcript: [te]}

      result = %OctoPi.Agent.Tool.Result{
        content: [%Content.Text{text: "permission denied"}],
        is_error?: true
      }

      ev = %Event.ToolExecutionEnd{tool_call_id: "tc3", tool_name: "Bash", result: result}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, ev})

      assert [%ToolExecution{status: :error, result: "permission denied"}] = s.transcript
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

  describe "crash-safe tty restoration" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Event, as: AIEvent
    alias OctoPi.AI.Model
    alias OctoPi.TUI.Terminal, as: TUITerminal

    setup do
      on_exit(&FakeTransport.clear/0)
      :ok
    end

    defp crash_safety_model do
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

    defp counting_raw_mode(test_pid) do
      fn action ->
        send(test_pid, {:raw_mode, action})
        :ok
      end
    end

    test "normal exit path calls raw_mode_fn.(:exit)" do
      test_pid = self()
      raw_mode_fn = counting_raw_mode(test_pid)
      terminal_name = :"crash_test_terminal_#{System.unique_integer([:positive])}"

      write_fn = fn _ ->
        send(test_pid, :frame_rendered)
        :ok
      end

      runner =
        Task.async(fn ->
          Interactive.run(
            model: crash_safety_model(),
            transport: FakeTransport,
            tools: [],
            write_fn: write_fn,
            raw_mode_fn: raw_mode_fn,
            skip_sigwinch: true,
            auto_start_reader: false,
            dimensions: {80, 24},
            terminal_name: terminal_name
          )
        end)

      assert_receive {:raw_mode, :enter}, 1_000
      assert_receive :frame_rendered, 1_000

      :ok = TUITerminal.feed_chunk(terminal_name, <<0x03>>)
      assert :ok = Task.await(runner, 2_000)

      assert_receive {:raw_mode, :exit}, 1_000
    end

    test "child crash still restores tty via the after block" do
      test_pid = self()
      raw_mode_fn = counting_raw_mode(test_pid)
      terminal_name = :"crash_test_terminal_#{System.unique_integer([:positive])}"

      write_fn = fn _ ->
        send(test_pid, :frame_rendered)
        :ok
      end

      runner =
        Task.async(fn ->
          Interactive.run(
            model: crash_safety_model(),
            transport: FakeTransport,
            tools: [],
            write_fn: write_fn,
            raw_mode_fn: raw_mode_fn,
            skip_sigwinch: true,
            auto_start_reader: false,
            dimensions: {80, 24},
            terminal_name: terminal_name
          )
        end)

      assert_receive {:raw_mode, :enter}, 1_000
      assert_receive :frame_rendered, 1_000

      # Hard-kill Terminal so its terminate/2 can't restore the tty.
      Process.exit(Process.whereis(terminal_name), :kill)

      assert :ok = Task.await(runner, 2_000)
      assert_receive {:raw_mode, :exit}, 1_000
    end
  end

  describe "render/1" do
    test "produces border + transcript + border + input" do
      s = %Interactive{
        transcript: [{:user, "hi"}, {:assistant, "hello!", :done}],
        input: %Input{value: "next", cursor: 4},
        width: 80
      }

      lines = Interactive.render(s)
      text = Enum.join(lines, "\n")

      assert text =~ "> hi"
      assert text =~ "hello!"
      assert text =~ "next"
      assert text =~ "─"
    end

    test "includes footer lines at the bottom" do
      alias OctoPi.TUI.Components.Footer

      footer = %Footer{
        cwd: "/tmp/test",
        model_id: "claude-opus-4-6",
        context_window: 200_000
      }

      s = %Interactive{
        transcript: [{:user, "hi"}],
        input: %Input{value: "", cursor: 0},
        footer: footer,
        width: 80,
        height: 24
      }

      lines = Interactive.render(s)
      text = Enum.join(lines, "\n")

      assert text =~ "/tmp/test"
      assert text =~ "claude-opus-4-6"
    end
  end

  describe "footer updates from agent events" do
    test "MessageEnd accumulates usage into footer" do
      alias OctoPi.TUI.Components.Footer

      footer = %Footer{
        cwd: "/tmp",
        model_id: "test-model",
        context_window: 100_000,
        input_tokens: 100,
        output_tokens: 50,
        cost: 0.001
      }

      s = %Interactive{footer: footer}

      msg = %Assistant{
        api: :fake,
        provider: :fake,
        model: "test-model",
        timestamp: 0,
        content: [%Content.Text{text: "reply"}],
        stop_reason: :stop,
        usage: %OctoPi.AI.Usage{
          input: 200,
          output: 100,
          cache_read: 50,
          cache_write: 25,
          cost: %OctoPi.AI.Usage.Cost{total: 0.002}
        }
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})

      assert s.footer.input_tokens == 300
      assert s.footer.output_tokens == 150
      assert s.footer.cache_read == 50
      assert s.footer.cache_write == 25
      assert_in_delta s.footer.cost, 0.003, 0.0001
    end
  end

  # ── UIContext wiring ────────────────────────────────────────────

  describe "build_ui_context/1" do
    test "all UIContext fields are bound functions" do
      ctx = Interactive.build_ui_context(self())
      fields = Map.from_struct(ctx)

      for {key, val} <- fields do
        assert is_function(val), "#{key} should be a function"
      end
    end

    test "returns a UIContext struct" do
      ctx = Interactive.build_ui_context(self())
      assert %UIContext{} = ctx
    end
  end

  describe "handle_ui_request — getters" do
    test "get_editor_text returns input value" do
      s = %Interactive{input: %Input{value: "hello"}}
      assert {^s, "hello"} = Interactive.handle_ui_request(s, :get_editor_text)
    end

    test "get_tools_expanded returns current value" do
      s = %Interactive{tools_expanded: true}
      assert {^s, true} = Interactive.handle_ui_request(s, :get_tools_expanded)
    end

    test "get_theme returns theme name" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{theme: theme}
      assert {^s, "dark"} = Interactive.handle_ui_request(s, :get_theme)
    end

    test "get_all_themes returns available theme names" do
      s = %Interactive{}
      {_s, themes} = Interactive.handle_ui_request(s, :get_all_themes)
      assert is_list(themes)
      assert "dark" in themes
    end
  end

  describe "handle_ui_request — setters" do
    test "set_editor_text replaces input value" do
      s = %Interactive{input: %Input{value: "old", cursor: 3}}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_editor_text, "new text"})
      assert s.input.value == "new text"
      assert s.input.cursor == 8
    end

    test "paste_to_editor inserts at cursor" do
      s = %Interactive{input: %Input{value: "hello world", cursor: 5}}
      {s, :ok} = Interactive.handle_ui_request(s, {:paste_to_editor, " there"})
      assert s.input.value == "hello there world"
    end

    test "set_tools_expanded updates state" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_tools_expanded, true})
      assert s.tools_expanded
    end

    test "set_theme reloads theme by name" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{theme: theme}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_theme, "light"})
      assert s.theme.name == "light"
    end

    test "notify sets notification text" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:notify, "saved!"})
      assert s.notification == "saved!"
    end

    test "set_working_message updates state" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_working_message, "thinking..."})
      assert s.working_message == "thinking..."
    end

    test "set_working_message nil clears it" do
      s = %Interactive{working_message: "old"}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_working_message, nil})
      assert s.working_message == nil
    end

    test "set_status stores status text" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "indexing..."})
      assert s.ui_overrides.status == "indexing..."
    end

    test "set_title stores title" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_title, "My Session"})
      assert s.ui_overrides.title == "My Session"
    end

    test "set_working_indicator updates state" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_working_indicator, true})
      assert s.ui_overrides.working_indicator
    end

    test "set_widget stores widget" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_widget, {:custom, "w"}})
      assert s.ui_overrides.widget == {:custom, "w"}
    end

    test "set_header stores header override" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_header, "custom header"})
      assert s.ui_overrides.header == "custom header"
    end

    test "set_footer stores footer override" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_footer, "custom footer"})
      assert s.ui_overrides.footer == "custom footer"
    end

    test "set_hidden_thinking_label stores label" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_hidden_thinking_label, "Reasoning"})
      assert s.ui_overrides.hidden_thinking_label == "Reasoning"
    end

    test "set_editor_component stores component" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_editor_component, :vim_input})
      assert s.ui_overrides.editor_component == :vim_input
    end

    test "add_autocomplete_provider wires into input" do
      alias OctoPi.TUI.Autocomplete
      alias OctoPi.TUI.Autocomplete.CombinedProvider

      s = %Interactive{}
      provider = fn _text -> ["suggestion"] end
      {s, :ok} = Interactive.handle_ui_request(s, {:add_autocomplete_provider, provider})
      assert %CombinedProvider{} = s.input.autocomplete_provider
      {:ok, items} = Autocomplete.get_suggestions(s.input.autocomplete_provider, "x")
      labels = Enum.map(items, & &1.label)
      assert "suggestion" in labels
    end
  end

  describe "handle_ui_request — blocking dialogs" do
    test "select stores pending dialog" do
      options = [%{label: "A", value: :a}, %{label: "B", value: :b}]
      ref = make_ref()
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:select, ref, options, []})
      assert s.dialog == {:select, ref, options, []}
    end

    test "confirm stores pending dialog" do
      ref = make_ref()
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:confirm, ref, "Sure?", []})
      assert s.dialog == {:confirm, ref, "Sure?", []}
    end

    test "input stores pending dialog" do
      ref = make_ref()
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:input, ref, "Name:", []})
      assert s.dialog == {:input, ref, "Name:", []}
    end

    test "editor stores pending dialog" do
      ref = make_ref()

      {s, :pending} =
        Interactive.handle_ui_request(%Interactive{}, {:editor, ref, "initial", []})

      assert s.dialog == {:editor, ref, "initial", []}
    end

    test "custom stores pending dialog" do
      ref = make_ref()
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:custom, ref, :my_ext, []})
      assert s.dialog == {:custom, ref, :my_ext, []}
    end
  end

  # ── Extension shortcuts ─────────────────────────────────────────

  describe "extension shortcuts" do
    test "matching shortcut consumes the key" do
      match_fn = fn
        %Key{key: ?x, modifiers: [:ctrl]} -> true
        _ -> false
      end

      handler = fn state -> %{state | notification: "shortcut fired"} end

      s = %Interactive{extension_shortcuts: [{match_fn, handler}]}
      s = Interactive.handle_event(s, {:key, %Key{key: ?x, modifiers: [:ctrl]}})
      assert s.notification == "shortcut fired"
    end

    test "non-matching shortcut falls through to normal handling" do
      match_fn = fn
        %Key{key: ?x, modifiers: [:ctrl]} -> true
        _ -> false
      end

      handler = fn state -> %{state | notification: "consumed"} end

      s = %Interactive{
        input: %Input{value: "abc", cursor: 3},
        extension_shortcuts: [{match_fn, handler}]
      }

      s = Interactive.handle_event(s, {:key, %Key{key: :left}})
      assert s.input.cursor == 2
      assert s.notification == nil
    end

    test "first matching shortcut wins" do
      m1 = fn
        %Key{key: ?a, modifiers: [:ctrl]} -> true
        _ -> false
      end

      h1 = fn state -> %{state | notification: "first"} end

      m2 = fn
        %Key{key: ?a, modifiers: [:ctrl]} -> true
        _ -> false
      end

      h2 = fn state -> %{state | notification: "second"} end

      s = %Interactive{extension_shortcuts: [{m1, h1}, {m2, h2}]}
      s = Interactive.handle_event(s, {:key, %Key{key: ?a, modifiers: [:ctrl]}})
      assert s.notification == "first"
    end

    test "Ctrl+C always exits regardless of shortcuts" do
      match_fn = fn _ -> true end
      handler = fn state -> %{state | notification: "blocked"} end

      s = %Interactive{extension_shortcuts: [{match_fn, handler}]}
      s = Interactive.handle_event(s, {:key, %Key{key: ?c, modifiers: [:ctrl]}})
      assert s.exit
      assert s.notification == nil
    end

    test "empty shortcuts list behaves normally" do
      s = %Interactive{input: %Input{value: "hi", cursor: 2}}
      s = Interactive.handle_event(s, {:key, %Key{key: :left}})
      assert s.input.cursor == 1
    end
  end
end
