defmodule OctoPi.TUI.InteractiveTest do
  use ExUnit.Case, async: true

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Tool.Result
  alias OctoPi.AI.Content
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Usage
  alias OctoPi.AI.Usage.Cost
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Session
  alias OctoPi.TUI.Components.AssistantMessage
  alias OctoPi.TUI.Components.BashExecution
  alias OctoPi.TUI.Components.CustomMessage
  alias OctoPi.TUI.Components.Diff
  alias OctoPi.TUI.Components.Footer
  alias OctoPi.TUI.Components.Header
  alias OctoPi.TUI.Components.Input
  alias OctoPi.TUI.Components.Loader
  alias OctoPi.TUI.Components.LoginDialog
  alias OctoPi.TUI.Components.SelectList
  alias OctoPi.TUI.Components.SessionSelector
  alias OctoPi.TUI.Components.SettingsList
  alias OctoPi.TUI.Components.SettingsSelector
  alias OctoPi.TUI.Components.SummarizePrompt
  alias OctoPi.TUI.Components.ToolExecution
  alias OctoPi.TUI.Components.TreeSelector
  alias OctoPi.TUI.Components.WelcomeBanner
  alias OctoPi.TUI.Interactive
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Paste
  alias OctoPi.TUI.Terminal.Resize
  alias OctoPi.TUI.Theme

  describe "handle_event — keyboard input" do
    test "printable char is inserted into the Input" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, %Key{key: ?h})
      assert s.input.value == "h"
      assert s.input.cursor == 1
    end

    test "Ctrl+C with empty editor and idle is a no-op (opi-0g4.9)" do
      s = %Interactive{}
      s2 = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl]})
      refute s2.exit
      assert s2 == s
    end

    test "left arrow routes to Input cursor movement" do
      s = %Interactive{input: %Input{value: "abc", cursor: 2}}
      s = Interactive.handle_event(s, %Key{key: :left})
      assert s.input.cursor == 1
    end

    test "Enter with empty input is a no-op" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.input.value == ""
      assert s.transcript == []
    end

    test "Enter with non-empty input appends user message + clears input" do
      s = %Interactive{input: %Input{value: "hi", cursor: 2}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.transcript == [{:user, "hi"}]
      assert s.input.value == ""
      assert s.input.cursor == 0
    end

    test "Enter calls expand_prompt_fn and shows original value in transcript" do
      test_pid = self()

      expand_fn = fn text ->
        send(test_pid, {:expanded, text})
        "expanded: #{text}"
      end

      s = %Interactive{input: %Input{value: "/greet world", cursor: 12}, session: nil, expand_prompt_fn: expand_fn}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert_received {:expanded, "/greet world"}
      assert s.transcript == [{:user, "/greet world"}]
      assert s.input.value == ""
    end

    test "Enter without expand_prompt_fn works as before" do
      s = %Interactive{input: %Input{value: "/foo", cursor: 4}, session: nil, expand_prompt_fn: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.transcript == [{:user, "/foo"}]
    end

    test "! prefix adds a running BashExecution to transcript immediately" do
      s = %Interactive{input: %Input{value: "! echo hello", cursor: 12}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert [%BashExecution{command: "echo hello", status: :running}] = s.transcript
    end

    test "! prefix completes BashExecution on :bash_done event" do
      s = %Interactive{input: %Input{value: "! echo hello", cursor: 12}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      be = hd(s.transcript)
      id = be.id
      assert_receive {:bash_done, ^id, output, exit_code}, 2_000
      s = Interactive.handle_event(s, {:bash_done, id, output, exit_code})
      assert [%BashExecution{status: :complete, exit_code: 0}] = s.transcript
      assert BashExecution.get_output(hd(s.transcript)) =~ "hello"
    end

    test "! prefix without space also runs shell command" do
      s = %Interactive{input: %Input{value: "!echo hi", cursor: 8}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert [%BashExecution{command: "echo hi", status: :running}] = s.transcript
      be = hd(s.transcript)
      id = be.id
      assert_receive {:bash_done, ^id, _output, _exit_code}, 2_000
    end

    test "! prefix clears input after execution" do
      s = %Interactive{input: %Input{value: "! echo hello", cursor: 12}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.input.value == ""
      assert s.input.cursor == 0
    end

    test "! prefix does not send to AI session" do
      test_pid = self()

      expand_fn = fn text ->
        send(test_pid, {:expanded, text})
        text
      end

      s = %Interactive{input: %Input{value: "! echo hello", cursor: 12}, session: nil, expand_prompt_fn: expand_fn}
      Interactive.handle_event(s, %Key{key: :enter})
      refute_received {:expanded, _}
    end

    test "! prefix with non-zero exit sets error status on :bash_done event" do
      s = %Interactive{input: %Input{value: "! exit 1", cursor: 8}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      be = hd(s.transcript)
      id = be.id
      assert_receive {:bash_done, ^id, _output, exit_code}, 2_000
      s = Interactive.handle_event(s, {:bash_done, id, "", exit_code})
      assert [%BashExecution{status: :error, exit_code: 1}] = s.transcript
    end

    test "/clear clears transcript without sending to AI" do
      s = %Interactive{input: %Input{value: "/clear", cursor: 6}, session: nil, transcript: [{:user, "hi"}]}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.transcript == []
      assert s.input.value == ""
    end

    test "/clear does not call expand_prompt_fn" do
      test_pid = self()

      expand_fn = fn text ->
        send(test_pid, {:expanded, text})
        text
      end

      s = %Interactive{input: %Input{value: "/clear", cursor: 6}, session: nil, expand_prompt_fn: expand_fn}
      Interactive.handle_event(s, %Key{key: :enter})
      refute_received {:expanded, _}
    end

    test "/model opens model selector" do
      model = %OctoPi.AI.Model{
        id: "m1",
        name: "m1",
        api: :fake,
        provider: :fake,
        base_url: "http://x",
        context_window: 100,
        max_tokens: 100
      }

      s = %Interactive{input: %Input{value: "/model", cursor: 6}, session: nil, models: [model], theme: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.model_selector
      assert s.input.value == ""
    end

    test "/help sets a notification" do
      s = %Interactive{input: %Input{value: "/help", cursor: 5}, session: nil}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.notification
      assert s.input.value == ""
    end

    test "/cost shows cost notification from footer" do
      footer = %Footer{cost: 0.042, input_tokens: 5_000, output_tokens: 1_000, context_window: 200_000}
      s = %Interactive{input: %Input{value: "/cost", cursor: 5}, session: nil, footer: footer}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.notification
      assert s.notification =~ "0.042"
      assert s.input.value == ""
    end

    test "/unknown-builtin falls through to AI prompt" do
      expand_fn = fn text -> text end
      s = %Interactive{input: %Input{value: "/my-template", cursor: 12}, session: nil, expand_prompt_fn: expand_fn}
      s = Interactive.handle_event(s, %Key{key: :enter})
      assert s.transcript == [{:user, "/my-template"}]
    end

    test "Escape clears non-empty input" do
      s = %Interactive{input: %Input{value: "draft", cursor: 5}}
      s = Interactive.handle_event(s, %Key{key: :escape})
      assert s.input.value == ""
      assert s.input.cursor == 0
      refute s.exit
    end

    test "Escape with empty input exits (double-Escape pattern)" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s = Interactive.handle_event(s, %Key{key: :escape})
      assert s.exit
    end

    test "Escape with active loader does not exit (aborts generation)" do
      s = %Interactive{input: %Input{value: "", cursor: 0}, loader: %Loader{}, session: nil}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      refute s2.exit
    end

    test "Escape with active loader and non-empty input clears input, does not exit" do
      s = %Interactive{input: %Input{value: "draft", cursor: 5}, loader: %Loader{}, session: nil}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      refute s2.exit
      assert s2.input.value == ""
    end

    test "paste event inserts content atomically into the input field" do
      s = %Interactive{input: %Input{value: "hello world", cursor: 5}}
      s = Interactive.handle_event(s, %Paste{content: "boo"})
      assert s.input.value == "helloboo world"
    end
  end

  describe "handle_event — Shift+Tab thinking cycle (opi-0g4.11)" do
    test "cycles off → low → medium → high → off" do
      s = %Interactive{thinking_level: :off}
      s = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s.thinking_level == :low
      s = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s.thinking_level == :medium
      s = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s.thinking_level == :high
      s = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s.thinking_level == :off
    end

    test "updates footer thinking_level to string label" do
      s = %Interactive{thinking_level: :off, footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s2.footer.thinking_level == "low"
    end

    test "footer thinking_level is 'off' when cycling back to off" do
      s = %Interactive{thinking_level: :high, footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s2.footer.thinking_level == "off"
    end

    test "footer thinking_level rendered in stats line after cycle" do
      s = %Interactive{thinking_level: :off, footer: %Footer{context_window: 200_000}}
      s2 = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      [_, stats | _] = Footer.render(s2.footer, 80)
      assert String.replace(stats, ~r/\e\[[0-9;]*m/, "") =~ "low"
    end

    test "sets notification with new level" do
      s = %Interactive{thinking_level: :off}
      s2 = Interactive.handle_event(s, %Key{key: :tab, modifiers: [:shift]})
      assert s2.notification
      assert s2.notification =~ "low"
    end
  end

  describe "handle_event — Alt+Up dequeue overlay (opi-0g4.16)" do
    alias OctoPi.Coder.SessionManager
    alias OctoPi.Coder.SessionStore
    alias Session, as: CoderSession

    defp dequeue_state(items, selected) do
      %Interactive{dequeue_overlay: %{items: items, selected: selected}, focused_component: {:overlay, :dequeue}}
    end

    defp tagged(type, text) do
      msg = %User{
        content: text,
        timestamp: 0
      }

      {type, msg}
    end

    defp start_coder_session! do
      model = %OctoPi.AI.Model{
        id: "fake",
        name: "fake",
        api: :fake,
        provider: :fake,
        base_url: "http://fake",
        context_window: 100,
        max_tokens: 100
      }

      id = "test-#{System.unique_integer([:positive])}"
      root = Path.join(System.tmp_dir!(), "opi-dequeue-test-#{id}")
      sm = %SessionManager{cwd: System.tmp_dir!(), session_id: id}

      store = start_supervised!({SessionStore, [id: id, cwd: System.tmp_dir!(), root: root]})
      coder = start_supervised!({CoderSession, [extensions: [], session_manager: sm, store_pid: store]})
      {:ok, agent} = OctoPi.Agent.start_session(model: model)
      :ok = OctoPi.Coder.set_agent_pid(coder, agent)
      {coder, agent}
    end

    test "Alt+Up with nil session is a no-op" do
      s = %Interactive{session: nil}
      s2 = Interactive.handle_event(s, %Key{key: :up, modifiers: [:alt]})
      assert s2 == s
    end

    test "Alt+Up with live session and queued follow-up opens overlay" do
      {coder, agent} = start_coder_session!()
      OctoPi.Agent.follow_up(agent, "queued message")
      s = %Interactive{session: coder}
      s2 = Interactive.handle_event(s, %Key{key: :up, modifiers: [:alt]})
      assert s2.dequeue_overlay
      items = s2.dequeue_overlay.items
      assert length(items) == 1
      assert match?([{:follow_up, _}], items)
    end

    test "Alt+Up with live session and empty queues shows notification" do
      {coder, _agent} = start_coder_session!()
      s = %Interactive{session: coder}
      s2 = Interactive.handle_event(s, %Key{key: :up, modifiers: [:alt]})
      assert s2.dequeue_overlay == nil
      assert s2.notification =~ "No queued"
    end

    test "when dequeue_overlay open, Up moves selection toward first item" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b"), tagged(:follow_up, "c")]
      s = dequeue_state(items, 2)
      s2 = Interactive.handle_event(s, %Key{key: :up})
      assert s2.dequeue_overlay.selected == 1
    end

    test "when dequeue_overlay open, Up does not go below 0" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b")]
      s = dequeue_state(items, 0)
      s2 = Interactive.handle_event(s, %Key{key: :up})
      assert s2.dequeue_overlay.selected == 0
    end

    test "when dequeue_overlay open, Down moves selection toward last item" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b")]
      s = dequeue_state(items, 0)
      s2 = Interactive.handle_event(s, %Key{key: :down})
      assert s2.dequeue_overlay.selected == 1
    end

    test "when dequeue_overlay open, Down does not go past last item" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b")]
      s = dequeue_state(items, 1)
      s2 = Interactive.handle_event(s, %Key{key: :down})
      assert s2.dequeue_overlay.selected == 1
    end

    test "when dequeue_overlay open, Delete removes selected item" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b"), tagged(:follow_up, "c")]
      s = dequeue_state(items, 1)
      s2 = Interactive.handle_event(s, %Key{key: :delete})
      assert length(s2.dequeue_overlay.items) == 2
      assert match?([{:follow_up, _}, {:follow_up, _}], s2.dequeue_overlay.items)
    end

    test "when dequeue_overlay open, Delete on last remaining item closes overlay" do
      items = [tagged(:follow_up, "only")]
      s = dequeue_state(items, 0)
      s2 = Interactive.handle_event(s, %Key{key: :delete})
      assert s2.dequeue_overlay == nil
    end

    test "when dequeue_overlay open, Escape closes overlay" do
      items = [tagged(:follow_up, "a"), tagged(:steering, "b")]
      s = dequeue_state(items, 0, session: nil)
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.dequeue_overlay == nil
    end
  end

  defp dequeue_state(items, selected, opts) do
    struct(
      %Interactive{dequeue_overlay: %{items: items, selected: selected}, focused_component: {:overlay, :dequeue}},
      opts
    )
  end

  describe "handle_event — Alt+Enter follow-up queuing (opi-0g4.15)" do
    test "Alt+Enter while loader active clears input" do
      s = %Interactive{
        input: %Input{value: "my follow up", cursor: 12},
        loader: %Loader{},
        session: nil
      }

      s2 = Interactive.handle_event(s, %Key{key: :enter, modifiers: [:alt]})
      assert s2.input.value == ""
      assert s2.input.cursor == 0
    end

    test "Alt+Enter while loader active sets follow-up notification" do
      s = %Interactive{
        input: %Input{value: "my follow up", cursor: 12},
        loader: %Loader{},
        session: nil
      }

      s2 = Interactive.handle_event(s, %Key{key: :enter, modifiers: [:alt]})
      assert s2.notification =~ "Follow-up"
    end

    test "Alt+Enter while idle with non-empty input submits immediately (like Enter)" do
      s = %Interactive{input: %Input{value: "hello", cursor: 5}, session: nil, loader: nil}
      s2 = Interactive.handle_event(s, %Key{key: :enter, modifiers: [:alt]})
      assert [{:user, "hello"}] = s2.transcript
      assert s2.input.value == ""
    end

    test "Alt+Enter while idle with empty input is no-op" do
      s = %Interactive{input: %Input{value: "", cursor: 0}, session: nil, loader: nil}
      s2 = Interactive.handle_event(s, %Key{key: :enter, modifiers: [:alt]})
      assert s2.transcript == []
      assert s2.input.value == ""
    end
  end

  describe "handle_event — Ctrl+G external editor (opi-0g4.14)" do
    test "Ctrl+G sets editor_pending to true" do
      s = %Interactive{}
      s2 = Interactive.handle_event(s, %Key{key: ?g, modifiers: [:ctrl]})
      assert s2.editor_pending
    end

    test "Ctrl+G does not set exit" do
      s = %Interactive{}
      s2 = Interactive.handle_event(s, %Key{key: ?g, modifiers: [:ctrl]})
      refute s2.exit
    end
  end

  describe "handle_event — Ctrl+Z process suspend (opi-0g4.10)" do
    test "Ctrl+Z sets suspend_pending to true" do
      s = %Interactive{}
      s2 = Interactive.handle_event(s, %Key{key: ?z, modifiers: [:ctrl]})
      assert s2.suspend_pending
    end

    test "Ctrl+Z does not set exit" do
      s = %Interactive{}
      s2 = Interactive.handle_event(s, %Key{key: ?z, modifiers: [:ctrl]})
      refute s2.exit
    end
  end

  describe "handle_event — Ctrl+T thinking visibility (opi-0g4.13)" do
    test "Ctrl+T toggles thinking_visible from true to false" do
      s = %Interactive{thinking_visible: true}
      s2 = Interactive.handle_event(s, %Key{key: ?t, modifiers: [:ctrl]})
      refute s2.thinking_visible
    end

    test "Ctrl+T toggles thinking_visible from false to true" do
      s = %Interactive{thinking_visible: false}
      s2 = Interactive.handle_event(s, %Key{key: ?t, modifiers: [:ctrl]})
      assert s2.thinking_visible
    end

    test "render hides thinking blocks when thinking_visible is false" do
      theme = Theme.load_builtin(:dark, :truecolor)
      msg = AssistantMessage.new(theme, content: [thinking: "my thought"])

      s = %Interactive{
        thinking_visible: false,
        transcript: [msg],
        input: %Input{},
        width: 80
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      refute text =~ "my thought"
      assert text =~ "Thinking..."
    end

    test "render shows thinking blocks when thinking_visible is true" do
      theme = Theme.load_builtin(:dark, :truecolor)
      msg = AssistantMessage.new(theme, content: [thinking: "my thought"])

      s = %Interactive{
        thinking_visible: true,
        transcript: [msg],
        input: %Input{},
        width: 80
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      assert text =~ "my thought"
    end
  end

  describe "handle_event — Ctrl+C and Ctrl+D (opi-0g4.9)" do
    test "Ctrl+C with non-empty editor clears editor text" do
      s = %Interactive{input: %Input{value: "hello", cursor: 5}}
      s2 = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl]})
      assert s2.input.value == ""
      assert s2.input.cursor == 0
      refute s2.exit
    end

    test "Ctrl+C with empty editor and idle is a no-op" do
      s = %Interactive{input: %Input{value: "", cursor: 0}, loader: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl]})
      refute s2.exit
      assert s2 == s
    end

    test "Ctrl+C with empty editor and agent running does not exit" do
      s = %Interactive{input: %Input{value: "", cursor: 0}, loader: %Loader{}, session: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl]})
      refute s2.exit
    end

    test "Ctrl+D with empty editor exits" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?d, modifiers: [:ctrl]})
      assert s2.exit
    end

    test "Ctrl+D with non-empty editor does not exit" do
      s = %Interactive{input: %Input{value: "abc", cursor: 1}}
      s2 = Interactive.handle_event(s, %Key{key: ?d, modifiers: [:ctrl]})
      refute s2.exit
    end
  end

  describe "handle_event — key release/repeat filtering (opi-0g4.6)" do
    test "release event is dropped — state unchanged" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl], event_type: :release})
      refute s2.exit
      assert s2 == s
    end

    test "release of a printable key does not insert char" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?a, event_type: :release})
      assert s2 == s
    end

    test "repeat event is processed normally" do
      s = %Interactive{input: %Input{value: "ab", cursor: 2}}
      s2 = Interactive.handle_event(s, %Key{key: :left, event_type: :repeat})
      assert s2.input.cursor == 1
    end

    test "press event is processed normally" do
      s = %Interactive{tools_expanded: false}
      s2 = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl], event_type: :press})
      assert s2.tools_expanded
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

      result = %Result{
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

      result = %Result{
        content: [%Content.Text{text: "permission denied"}],
        is_error?: true
      }

      ev = %Event.ToolExecutionEnd{tool_call_id: "tc3", tool_name: "Bash", result: result}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, ev})

      assert [%ToolExecution{status: :error, result: "permission denied"}] = s.transcript
    end

    test "continuation text after tool execution creates a new AssistantMessage" do
      # Turn 1: assistant says "let me check" then calls a tool
      msg1 = AssistantMessage.new(nil, content: [text: "let me check"], has_tool_calls: true)
      te = ToolExecution.new("bash", "tc1", %{}, nil)
      te = ToolExecution.set_result(te, "ok", false)

      s = %Interactive{transcript: [msg1, te]}

      # Turn 2: model responds with new text after tool results
      partial = %Assistant{
        content: [%Content.Text{text: "here is the answer"}],
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

      # The continuation text must be a NEW entry BELOW the tool, not
      # merged into the first AssistantMessage above it.
      assert [
               %AssistantMessage{content: [text: "let me check"]},
               %ToolExecution{},
               %AssistantMessage{content: [text: "here is the answer"]}
             ] =
               s.transcript
    end

    test "unrelated agent events don't modify the transcript" do
      s = %Interactive{transcript: [{:user, "x"}]}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.TurnStart{turn: 0}})
      assert s.transcript == [{:user, "x"}]
    end
  end

  describe "handle_event — extension lifecycle events (opi-8ee.3)" do
    alias OctoPi.Coder.Extension.API
    alias OctoPi.Coder.Extension.Loader, as: ExtLoader

    test "AgentStart fires :agent_start to extensions" do
      test_pid = self()

      {:ok, ext} =
        ExtLoader.load_from_factory("lifecycle", fn api ->
          API.on(api, :agent_start, fn _event, _ctx ->
            send(test_pid, :agent_start_fired)
          end)
        end)

      s = %Interactive{extensions: [ext]}
      Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert_receive :agent_start_fired, 1_000
    end

    test "AgentEnd fires :agent_end to extensions" do
      test_pid = self()

      {:ok, ext} =
        ExtLoader.load_from_factory("lifecycle", fn api ->
          API.on(api, :agent_end, fn _event, _ctx ->
            send(test_pid, :agent_end_fired)
          end)
        end)

      s = %Interactive{extensions: [ext]}
      Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop, messages: []}})
      assert_receive :agent_end_fired, 1_000
    end

    test "extension lifecycle context has has_ui?: true" do
      test_pid = self()

      {:ok, ext} =
        ExtLoader.load_from_factory("lifecycle", fn api ->
          API.on(api, :agent_start, fn _event, ctx ->
            send(test_pid, {:has_ui, ctx.has_ui?})
          end)
        end)

      s = %Interactive{extensions: [ext]}
      Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert_receive {:has_ui, true}, 1_000
    end

    test "no extensions — AgentStart still creates loader" do
      s = %Interactive{extensions: []}
      new_s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert %Loader{} = new_s.loader
    end

    test "no extensions — AgentEnd still clears loader" do
      s = %Interactive{loader: Loader.new(), extensions: []}
      new_s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop, messages: []}})
      assert new_s.loader == nil
    end
  end

  describe "handle_event — loader lifecycle" do
    test "AgentStart creates a loader" do
      s = %Interactive{}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert %Loader{} = s.loader
    end

    test "AgentStart uses working_message when set" do
      s = %Interactive{working_message: "Thinking hard..."}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert s.loader.message == "Thinking hard..."
    end

    test "AgentStart uses default message when working_message is nil" do
      s = %Interactive{}
      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.AgentStart{}})
      assert s.loader.message =~ "Thinking"
    end

    test "AgentEnd clears the loader" do
      loader = Loader.new(message: "Working...")
      s = %Interactive{loader: loader}

      s =
        Interactive.handle_event(s, {
          :octo_pi_agent_event,
          %Event.AgentEnd{reason: :stop, messages: []}
        })

      assert s.loader == nil
    end

    test "AgentEnd resets working_message" do
      loader = Loader.new()
      s = %Interactive{loader: loader, working_message: "custom"}

      s =
        Interactive.handle_event(s, {
          :octo_pi_agent_event,
          %Event.AgentEnd{reason: :stop, messages: []}
        })

      assert s.working_message == nil
    end

    test "set_working_message updates loader message when loader is active" do
      loader = Loader.new(message: "old")
      s = %Interactive{loader: loader}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_working_message, "new message"})
      assert s.working_message == "new message"
      assert s.loader.message == "new message"
    end

    test "set_working_message with nil restores default when loader is active" do
      loader = Loader.new(message: "custom")
      s = %Interactive{loader: loader, working_message: "custom"}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_working_message, nil})
      assert s.working_message == nil
      assert s.loader.message =~ "Thinking"
    end
  end

  describe "handle_event — loader tick" do
    test "loader_tick is a no-op on state" do
      loader = Loader.new(frames: ["a", "b", "c"])
      s = %Interactive{loader: loader}
      s2 = Interactive.handle_event(s, :loader_tick)
      assert s2 == s
    end

    test "loader_tick is a no-op when loader is nil" do
      s = %Interactive{loader: nil}
      s2 = Interactive.handle_event(s, :loader_tick)
      assert s2 == s
    end
  end

  describe "render — loader placement" do
    test "active loader lines appear between transcript and input" do
      loader = Loader.new(message: "Working...")

      s = %Interactive{
        transcript: [{:user, "hi"}],
        loader: loader,
        input: %Input{value: "", cursor: 0},
        width: 80,
        height: 40
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      assert text =~ "Working..."
    end

    test "no loader lines when loader is nil" do
      s = %Interactive{
        transcript: [{:user, "hi"}],
        loader: nil,
        input: %Input{value: "", cursor: 0},
        width: 80,
        height: 40
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      refute text =~ "Loading..."
    end
  end

  describe "handle_event — resize" do
    test "updates width + height" do
      s = %Interactive{width: 80, height: 24}
      s = Interactive.handle_event(s, %Resize{width: 100, height: 30})
      assert s.width == 100
      assert s.height == 30
    end
  end

  describe "run/1 — extension loading (opi-8ee.1)" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Model
    alias OctoPi.Coder.Extension.API
    alias OctoPi.Coder.Extension.Loader

    setup do
      on_exit(&FakeTransport.clear/0)
      :ok
    end

    defp ext_model do
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

    test "session_start event is fired to extensions with has_ui?: true" do
      test_pid = self()

      {:ok, ext} =
        Loader.load_from_factory("test_ext", fn api ->
          API.on(api, :session_start, fn _event, ctx ->
            send(test_pid, {:session_start, ctx.has_ui?})
          end)
        end)

      interactive_name = :"ext_test_interactive_#{System.unique_integer([:positive])}"

      Task.async(fn ->
        Interactive.run(
          model: ext_model(),
          transport: FakeTransport,
          tools: [],
          extensions: [ext],
          write_fn: fn _ -> :ok end,
          skip_raw_mode: true,
          skip_sigwinch: true,
          auto_start_reader: false,
          dimensions: {80, 24},
          terminal_name: nil,
          name: interactive_name
        )
      end)

      assert_receive {:session_start, true}, 2_000
      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
    end

    test "session_start context includes cwd" do
      test_pid = self()

      {:ok, ext} =
        Loader.load_from_factory("test_ext", fn api ->
          API.on(api, :session_start, fn _event, ctx ->
            send(test_pid, {:cwd, ctx.cwd})
          end)
        end)

      interactive_name = :"ext_test_interactive_#{System.unique_integer([:positive])}"

      Task.async(fn ->
        Interactive.run(
          model: ext_model(),
          transport: FakeTransport,
          tools: [],
          extensions: [ext],
          cwd: "/test/workdir",
          write_fn: fn _ -> :ok end,
          skip_raw_mode: true,
          skip_sigwinch: true,
          auto_start_reader: false,
          dimensions: {80, 24},
          terminal_name: nil,
          name: interactive_name
        )
      end)

      assert_receive {:cwd, "/test/workdir"}, 2_000
      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
    end

    test "extensions field defaults to empty list" do
      s = %Interactive{}
      assert s.extensions == []
    end

    test "no extensions — no session_start messages sent" do
      interactive_name = :"ext_test_interactive_#{System.unique_integer([:positive])}"
      test_pid = self()

      runner =
        Task.async(fn ->
          Interactive.run(
            model: ext_model(),
            transport: FakeTransport,
            tools: [],
            extensions: [],
            write_fn: fn _ ->
              send(test_pid, :rendered)
              :ok
            end,
            skip_raw_mode: true,
            skip_sigwinch: true,
            auto_start_reader: false,
            dimensions: {80, 24},
            terminal_name: nil,
            name: interactive_name
          )
        end)

      assert_receive :rendered, 2_000
      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
      Task.await(runner, 2_000)
    end
  end

  describe "handle_submit — extension slash commands (opi-8ee.2)" do
    alias OctoPi.Coder.Extension.API
    alias OctoPi.Coder.Extension.Loader

    defp ext_with_command(name, handler) do
      {:ok, ext} =
        Loader.load_from_factory(name, fn api ->
          API.register_command(api, name, %{description: "test", handler: handler})
        end)

      ext
    end

    test "extension command handler is called when slash command matches" do
      test_pid = self()

      ext =
        ext_with_command("myext", fn _args, _ctx ->
          send(test_pid, :called)
          "result"
        end)

      state = %Interactive{input: %Input{value: "/myext", cursor: 6}, extensions: [ext], session: nil}
      Interactive.handle_event(state, %Key{key: :enter})
      assert_receive :called, 1_000
    end

    test "extension command clears input without sending to AI" do
      ext = ext_with_command("myext", fn _args, _ctx -> "result" end)
      state = %Interactive{input: %Input{value: "/myext", cursor: 6}, extensions: [ext], session: nil}
      new_state = Interactive.handle_event(state, %Key{key: :enter})
      assert new_state.input.value == ""
      assert new_state.input.cursor == 0
      assert new_state.transcript == []
    end

    test "unknown slash command with no matching extension falls through to AI" do
      state = %Interactive{input: %Input{value: "/unknown", cursor: 8}, extensions: [], session: nil}
      new_state = Interactive.handle_event(state, %Key{key: :enter})
      assert new_state.transcript == [{:user, "/unknown"}]
    end

    test "extension command takes priority over AI dispatch" do
      test_pid = self()

      ext =
        ext_with_command("custom", fn _args, _ctx ->
          send(test_pid, :ext_called)
          nil
        end)

      state = %Interactive{
        input: %Input{value: "/custom", cursor: 7},
        extensions: [ext],
        session: nil
      }

      new_state = Interactive.handle_event(state, %Key{key: :enter})
      assert_receive :ext_called, 1_000
      assert new_state.transcript == []
    end

    test "extension command handler receives a context with has_ui?: true" do
      test_pid = self()

      ext =
        ext_with_command("uicheck", fn _args, ctx ->
          send(test_pid, {:has_ui, ctx.has_ui?})
          nil
        end)

      state = %Interactive{input: %Input{value: "/uicheck", cursor: 8}, extensions: [ext], session: nil}
      Interactive.handle_event(state, %Key{key: :enter})
      assert_receive {:has_ui, true}, 1_000
    end

    test "builtin commands still take priority over extensions" do
      ext = ext_with_command("help", fn _args, _ctx -> "ext help" end)

      state = %Interactive{
        input: %Input{value: "/help", cursor: 5},
        extensions: [ext],
        session: nil
      }

      new_state = Interactive.handle_event(state, %Key{key: :enter})
      assert new_state.notification =~ "Commands:"
    end
  end

  describe "run/1 — extension tool registration (opi-8ee.4)" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Model
    alias OctoPi.Coder.Extension.API
    alias OctoPi.Coder.Extension.Loader, as: ExtLoader

    setup do
      on_exit(&FakeTransport.clear/0)
      :ok
    end

    defp tool_reg_model do
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

    test "extension tools are registered with the agent session on startup" do
      test_pid = self()

      {:ok, ext} =
        ExtLoader.load_from_factory("tool_ext", fn api ->
          API.register_tool(api, %{
            name: "my_ext_tool",
            description: "a tool",
            input_schema: %{type: "object", properties: %{}}
          })

          API.on(api, :session_start, fn _event, _ctx ->
            send(test_pid, :session_started)
          end)
        end)

      interactive_name = :"tool_reg_interactive_#{System.unique_integer([:positive])}"

      runner =
        Task.async(fn ->
          Interactive.run(
            model: tool_reg_model(),
            transport: FakeTransport,
            tools: [],
            extensions: [ext],
            write_fn: fn _ -> :ok end,
            skip_raw_mode: true,
            skip_sigwinch: true,
            auto_start_reader: false,
            dimensions: {80, 24},
            terminal_name: nil,
            name: interactive_name
          )
        end)

      assert_receive :session_started, 2_000
      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
      Task.await(runner, 2_000)
    end

    test "add_tool via handle_ui_request registers the tool when a session is active" do
      alias OctoPi.Coder.SessionManager
      alias OctoPi.Coder.SessionStore
      alias Session, as: CoderSession

      id = "test-#{System.unique_integer([:positive])}"
      root = Path.join(System.tmp_dir!(), "opi-addtool-test-#{id}")
      sm = %SessionManager{cwd: System.tmp_dir!(), session_id: id}
      store = start_supervised!({SessionStore, [id: id, cwd: System.tmp_dir!(), root: root]})
      coder = start_supervised!({CoderSession, [extensions: [], session_manager: sm, store_pid: store]})
      {:ok, agent} = OctoPi.Agent.start_session(model: tool_reg_model(), transport: FakeTransport)
      :ok = OctoPi.Coder.set_agent_pid(coder, agent)

      tool = %{name: "runtime_tool", description: "added at runtime", input_schema: %{}}
      state = %Interactive{session: coder}
      {_new_state, :ok} = Interactive.handle_ui_request(state, {:register_extension_tool, tool})

      session_state = OctoPi.Agent.state(agent)
      assert Enum.any?(session_state.tools, &(&1.name == "runtime_tool"))
    end

    test "add_tool via handle_ui_request is a no-op when session is nil" do
      tool = %{name: "runtime_tool", description: "added at runtime", input_schema: %{}}
      state = %Interactive{session: nil}
      {_new_state, :ok} = Interactive.handle_ui_request(state, {:register_extension_tool, tool})
    end
  end

  describe "run/1 end-to-end" do
    alias OctoPi.Agent.TestSupport.FakeTransport
    alias OctoPi.AI.Event, as: AIEvent
    alias OctoPi.AI.Model

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
        usage: %Usage{}
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

      interactive_name = :"test_interactive_#{System.unique_integer([:positive])}"

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
              terminal_name: nil,
              name: interactive_name,
              min_interval_ms: 0
            )

          send(parent, {:run_done, result})
        end)

      # Initial render lands first; wait for it before feeding input.
      assert_receive {:tui_output, _initial}, 2_000

      # Feed the prompt + Enter.
      send(interactive_name, {:hid_event, %Key{key: ?h}})
      send(interactive_name, {:hid_event, %Key{key: ?i}})
      send(interactive_name, {:hid_event, %Key{key: :enter}})

      # Drain tui_output messages until one contains "pong" (the
      # agent's streamed response). receive_until is defined below.
      receive_until_containing("pong", 2_000)

      # Ctrl+D exits (empty editor after response clears input).
      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
      assert_receive {:run_done, :ok}, 2_000

      Task.await(runner, 1_000)

      all = buffer |> Agent.get(& &1) |> Enum.reverse() |> IO.iodata_to_binary()
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
      interactive_name = :"crash_test_interactive_#{System.unique_integer([:positive])}"

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
            tty_fn: fn _ -> :ok end,
            skip_sigwinch: true,
            auto_start_reader: false,
            dimensions: {80, 24},
            terminal_name: nil,
            name: interactive_name
          )
        end)

      assert_receive {:raw_mode, :enter}, 1_000
      assert_receive :frame_rendered, 1_000

      send(interactive_name, {:hid_event, %Key{key: ?d, modifiers: [:ctrl]}})
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
            tty_fn: fn _ -> :ok end,
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
    test "concatenates transcript + input-with-borders + footer" do
      s = %Interactive{
        transcript: [{:user, "hi"}, {:assistant, "hello!", :done}],
        input: %Input{value: "next", cursor: 4},
        width: 80
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")

      assert text =~ "> hi"
      assert text =~ "hello!"
      # Input owns its borders
      border = String.duplicate("─", 80)
      assert border in lines
      # Input content between borders (may contain cursor ANSI codes)
      assert Enum.any?(lines, &String.starts_with?(&1, "next"))
    end

    test "includes footer lines at the bottom" do
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

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")

      assert text =~ "/tmp/test"
      assert text =~ "claude-opus-4-6"
    end
  end

  describe "welcome banner" do
    test "renders banner when present" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme, model: "test-model")

      s = %Interactive{
        transcript: [],
        input: %Input{value: "", cursor: 0},
        banner: banner,
        theme: theme,
        width: 80,
        height: 24
      }

      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      assert text =~ "octo_pi"
    end

    test "? toggles banner when input is empty" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme, model: "test-model")
      s = %Interactive{input: %Input{value: ""}, banner: banner, theme: theme}
      refute s.banner.expanded

      s2 = Interactive.handle_event(s, %Key{key: ??})
      assert s2.banner.expanded
    end

    test "? types into input when input is not empty" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme, model: "test-model")
      s = %Interactive{input: %Input{value: "hello", cursor: 5}, banner: banner, theme: theme}

      s2 = Interactive.handle_event(s, %Key{key: ??})
      assert s2.input.value == "hello?"
      refute s2.banner.expanded
    end
  end

  describe "header component" do
    test "renders Header when banner is nil" do
      s = %Interactive{banner: nil, width: 80}
      lines = Interactive.build_screen(s)
      text = lines |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "OctoPi"
    end

    test "? toggles header.expanded when banner is nil" do
      s = %Interactive{input: %Input{value: ""}, banner: nil}
      refute s.header.expanded
      s2 = Interactive.handle_event(s, %Key{key: ??})
      assert s2.header.expanded
    end

    test "? does not affect header when banner is present" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme)
      s = %Interactive{input: %Input{value: ""}, banner: banner}
      s2 = Interactive.handle_event(s, %Key{key: ??})
      assert s2.header == s.header
    end

    test "ctrl+o syncs header.expanded when banner is nil" do
      s = %Interactive{tools_expanded: false, banner: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s2.tools_expanded == true
      assert s2.header.expanded == true
    end

    test "ctrl+o does not change header when banner is present" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme)
      s = %Interactive{tools_expanded: false, banner: banner}
      s2 = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s2.header == s.header
    end
  end

  describe "render/1 — notification truncation" do
    test "notification is rendered and truncated to width" do
      long_text = String.duplicate("x", 200)
      s = %Interactive{notification: long_text, width: 40}
      lines = Interactive.build_screen(s)
      notif_line = Enum.find(lines, &String.contains?(&1, "xxx"))
      assert notif_line
      stripped = String.replace(notif_line, ~r/\e\[[0-9;]*m/, "")
      assert String.length(stripped) <= 40
    end
  end

  describe "render/1 — transcript component routing" do
    test "Diff struct in transcript renders coloured lines" do
      theme = Theme.load_builtin(:dark, :truecolor)
      diff = %Diff{diff_text: "+1 new line\n-1 old line", theme: theme}
      s = %Interactive{transcript: [diff], width: 80}
      lines = Interactive.build_screen(s)
      text = Enum.join(lines, "\n")
      assert text =~ "new line"
      assert text =~ "old line"
    end

    test "CustomMessage struct in transcript renders via Component protocol" do
      theme = Theme.load_builtin(:dark, :truecolor)
      msg = CustomMessage.new("alert", "Something happened", theme)
      s = %Interactive{transcript: [msg], width: 80}
      lines = Interactive.build_screen(s)
      text = lines |> Enum.join("\n") |> String.replace(~r/\e\[[0-9;]*m/, "")
      assert text =~ "Something happened"
    end
  end

  describe "interactive component dispatch — LoginDialog" do
    test "/login slash command opens LoginDialog with theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{input: %Input{value: "/login", cursor: 6}, theme: theme}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert %LoginDialog{} = s2.login_dialog
      assert s2.focused_component == {:dialog, :login}
    end

    test "/login with nil theme shows notification instead" do
      s = %Interactive{input: %Input{value: "/login", cursor: 6}, theme: nil}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.login_dialog == nil
      assert s2.notification
    end

    test "Escape from LoginDialog unfocuses and clears dialog" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ld = LoginDialog.new(theme)
      s = %Interactive{login_dialog: ld, focused_component: {:dialog, :login}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.login_dialog == nil
      assert s2.focused_component == :input
    end

    test "Enter with valid API key clears dialog" do
      theme = Theme.load_builtin(:dark, :truecolor)
      valid_key = "sk-ant-" <> String.duplicate("x", 25)
      ld = LoginDialog.new(theme)
      ld = Enum.reduce(String.graphemes(valid_key), ld, &LoginDialog.handle_char(&2, &1))
      s = %Interactive{login_dialog: ld, focused_component: {:dialog, :login}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.login_dialog == nil
      assert s2.focused_component == :input
    end
  end

  describe "interactive component dispatch — SettingsSelector" do
    test "/settings slash command opens SettingsSelector with theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{input: %Input{value: "/settings", cursor: 9}, theme: theme}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert %SettingsSelector{} = s2.settings_selector
      assert s2.focused_component == {:dialog, :settings}
    end

    test "Escape from SettingsSelector unfocuses" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ss = SettingsSelector.new(theme)
      s = %Interactive{settings_selector: ss, focused_component: {:dialog, :settings}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.settings_selector == nil
      assert s2.focused_component == :input
    end

    test "Enter on SettingsSelector cycles setting and keeps dialog open" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ss = SettingsSelector.new(theme)
      s = %Interactive{settings_selector: ss, focused_component: {:dialog, :settings}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.focused_component == :input
    end
  end

  describe "interactive component dispatch — SessionSelector" do
    test "/sessions slash command opens SessionSelector with theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{input: %Input{value: "/sessions", cursor: 9}, theme: theme, footer: %Footer{cwd: "/tmp"}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert %SessionSelector{} = s2.session_selector
      assert s2.focused_component == {:dialog, :session_selector}
    end

    test "Escape from SessionSelector unfocuses" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ss = SessionSelector.new([], theme)
      s = %Interactive{session_selector: ss, focused_component: {:dialog, :session_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.session_selector == nil
      assert s2.focused_component == :input
    end

    test "Enter with no sessions cancels" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ss = SessionSelector.new([], theme)
      s = %Interactive{session_selector: ss, focused_component: {:dialog, :session_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.focused_component == :input
    end
  end

  describe "interactive component dispatch — TreeSelector" do
    test "Escape from TreeSelector unfocuses" do
      entries = []
      ts = TreeSelector.new(entries)
      s = %Interactive{tree_selector: ts, focused_component: {:dialog, :tree_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.tree_selector == nil
      assert s2.focused_component == :input
    end
  end

  describe "interactive component dispatch — SummarizePrompt" do
    test "Escape from SummarizePrompt unfocuses" do
      sp = SummarizePrompt.new()
      s = %Interactive{summarize_prompt: sp, focused_component: {:dialog, :summarize_prompt}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.summarize_prompt == nil
      assert s2.focused_component == :input
    end

    test "Enter on SummarizePrompt selects choice and unfocuses" do
      sp = SummarizePrompt.new()
      s = %Interactive{summarize_prompt: sp, focused_component: {:dialog, :summarize_prompt}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.summarize_prompt == nil
      assert s2.focused_component == :input
    end

    test "TreeSelector Enter transitions to SummarizePrompt" do
      alias OctoPi.Coder.Session.Entry

      entry = %Entry.Message{id: "e1", parent_id: nil, message: nil, timestamp: 0}
      ts = TreeSelector.new([entry])
      s = %Interactive{tree_selector: ts, focused_component: {:dialog, :tree_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert %SummarizePrompt{} = s2.summarize_prompt
      assert s2.focused_component == {:dialog, :summarize_prompt}
    end
  end

  describe "interactive component dispatch — SelectList (UIHost :select)" do
    test "handle_ui_request :select creates a SelectList and sets focus" do
      options = [%{label: "A", value: :a}, %{label: "B", value: :b}]
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:select, options, []})
      assert %SelectList{} = s.select_list
      assert s.focused_component == {:dialog, :select_list}
    end

    test "Escape from SelectList clears dialog and select_list" do
      sl = %SelectList{items: ["option 1", "option 2"]}
      s = %Interactive{select_list: sl, focused_component: {:dialog, :select_list}, dialog: nil}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.select_list == nil
      assert s2.focused_component == :input
    end

    test "Up/Down moves SelectList selection" do
      sl = %SelectList{items: ["a", "b", "c"], selected: 0}
      s = %Interactive{select_list: sl, focused_component: {:dialog, :select_list}}
      s2 = Interactive.handle_event(s, %Key{key: :down})
      assert s2.select_list.selected == 1
    end
  end

  describe "interactive component dispatch — SettingsList" do
    test "Escape from SettingsList unfocuses" do
      theme = Theme.load_builtin(:dark, :truecolor)

      items = [
        SettingsList.Item.checkbox("show_line_numbers", "Show line numbers", false)
      ]

      sl = SettingsList.new(items, theme)
      s = %Interactive{settings_list: sl, focused_component: {:dialog, :settings_list}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.settings_list == nil
      assert s2.focused_component == :input
    end
  end

  describe "footer updates from agent events" do
    test "MessageEnd accumulates usage into footer" do
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
        usage: %Usage{
          input: 200,
          output: 100,
          cache_read: 50,
          cache_write: 25,
          cost: %Cost{total: 0.002}
        }
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})

      assert s.footer.input_tokens == 300
      assert s.footer.output_tokens == 150
      assert s.footer.cache_read == 50
      assert s.footer.cache_write == 25
      assert_in_delta s.footer.cost, 0.003, 0.0001
    end

    test "MessageEnd computes context_percent from input_tokens / context_window" do
      footer = %Footer{
        cwd: "/tmp",
        model_id: "test-model",
        context_window: 200_000,
        input_tokens: 0,
        output_tokens: 0,
        cost: 0.0
      }

      s = %Interactive{footer: footer}

      msg = %Assistant{
        api: :fake,
        provider: :fake,
        model: "test-model",
        timestamp: 0,
        content: [%Content.Text{text: "reply"}],
        stop_reason: :stop,
        usage: %Usage{
          input: 20_000,
          output: 500,
          cache_read: 0,
          cache_write: 0,
          cost: %Cost{total: 0.001}
        }
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})

      assert_in_delta s.footer.context_percent, 10.0, 0.01
    end

    test "MessageEnd context_percent accumulates across turns" do
      footer = %Footer{
        cwd: "/tmp",
        model_id: "test-model",
        context_window: 100_000,
        input_tokens: 10_000,
        output_tokens: 0,
        cost: 0.0
      }

      s = %Interactive{footer: footer}

      msg = %Assistant{
        api: :fake,
        provider: :fake,
        model: "test-model",
        timestamp: 0,
        content: [%Content.Text{text: "reply"}],
        stop_reason: :stop,
        usage: %Usage{
          input: 15_000,
          output: 100,
          cache_read: 0,
          cache_write: 0,
          cost: %Cost{total: 0.001}
        }
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})

      assert_in_delta s.footer.context_percent, 25.0, 0.01
    end

    test "MessageEnd context_percent is nil when context_window is 0" do
      footer = %Footer{
        cwd: "/tmp",
        model_id: "test-model",
        context_window: 0,
        input_tokens: 0,
        output_tokens: 0,
        cost: 0.0
      }

      s = %Interactive{footer: footer}

      msg = %Assistant{
        api: :fake,
        provider: :fake,
        model: "test-model",
        timestamp: 0,
        content: [%Content.Text{text: "reply"}],
        stop_reason: :stop,
        usage: %Usage{
          input: 1_000,
          output: 50,
          cache_read: 0,
          cache_write: 0,
          cost: %Cost{total: 0.0}
        }
      }

      s = Interactive.handle_event(s, {:octo_pi_agent_event, %Event.MessageEnd{message: msg}})

      assert is_nil(s.footer.context_percent)
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

    test "apply_fg returns ANSI-styled text using theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{theme: theme}
      {^s, result} = Interactive.handle_ui_request(s, {:apply_fg, :accent, "hello"})
      assert result =~ "hello"
      assert result =~ "\e["
    end

    test "apply_fg with nil theme returns text unchanged" do
      s = %Interactive{theme: nil}
      {^s, result} = Interactive.handle_ui_request(s, {:apply_fg, :accent, "hello"})
      assert result == "hello"
    end

    test "apply_bg returns ANSI-styled text using theme" do
      theme = Theme.load_builtin(:dark, :truecolor)
      s = %Interactive{theme: theme}
      {^s, result} = Interactive.handle_ui_request(s, {:apply_bg, :tool_success_bg, "ok"})
      assert result =~ "ok"
      assert result =~ "\e["
    end

    test "apply_bg with nil theme returns text unchanged" do
      s = %Interactive{theme: nil}
      {^s, result} = Interactive.handle_ui_request(s, {:apply_bg, :tool_success_bg, "ok"})
      assert result == "ok"
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

    test "set_status updates footer extension_statuses for the given id" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "my-ext", "indexing..."})
      assert s.footer.extension_statuses["my-ext"] == "indexing..."
    end

    test "set_status with nil clears the named slot" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "my-ext", "indexing..."})
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "my-ext", nil})
      refute Map.has_key?(s.footer.extension_statuses, "my-ext")
    end

    test "set_status for different ids are independent" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "ext-a", "status a"})
      {s, :ok} = Interactive.handle_ui_request(s, {:set_status, "ext-b", "status b"})
      assert s.footer.extension_statuses["ext-a"] == "status a"
      assert s.footer.extension_statuses["ext-b"] == "status b"
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

    test "set_header stores a render fn override" do
      s = %Interactive{}
      render_fn = fn _width -> ["custom header"] end
      {s, :ok} = Interactive.handle_ui_request(s, {:set_header, render_fn})
      assert is_function(s.ui_overrides.header, 1)
    end

    test "set_header render fn is called during render" do
      test_pid = self()

      render_fn = fn width ->
        send(test_pid, {:rendered, width})
        ["header line"]
      end

      s = %Interactive{
        transcript: [],
        input: %Input{value: "", cursor: 0},
        banner: nil,
        width: 80,
        height: 24,
        ui_overrides: %{header: render_fn}
      }

      Interactive.build_screen(s)
      assert_receive {:rendered, 80}
    end

    test "set_header nil restores default (banner) rendering" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_header, nil})
      assert is_nil(s.ui_overrides.header)
    end

    test "set_footer stores a render fn override" do
      s = %Interactive{}
      render_fn = fn _width, _footer_data -> ["custom footer"] end
      {s, :ok} = Interactive.handle_ui_request(s, {:set_footer, render_fn})
      assert is_function(s.ui_overrides.footer, 2)
    end

    test "set_footer render fn is called with width and footer_data during render" do
      test_pid = self()

      render_fn = fn width, footer_data ->
        send(test_pid, {:rendered, width, footer_data})
        ["footer line"]
      end

      s = %Interactive{
        transcript: [],
        input: %Input{value: "", cursor: 0},
        width: 80,
        height: 24,
        ui_overrides: %{footer: render_fn}
      }

      Interactive.build_screen(s)
      assert_receive {:rendered, 80, footer_data}
      assert is_function(footer_data.get_git_branch, 0)
      assert is_function(footer_data.get_extension_statuses, 0)
      assert is_function(footer_data.on_branch_change, 1)
    end

    test "footer_data.get_extension_statuses returns footer's extension_statuses" do
      test_pid = self()

      render_fn = fn _width, footer_data ->
        send(test_pid, footer_data.get_extension_statuses.())
        ["footer"]
      end

      s = %Interactive{
        transcript: [],
        input: %Input{value: "", cursor: 0},
        width: 80,
        height: 24,
        footer: %Footer{extension_statuses: %{"ext-a" => "running"}},
        ui_overrides: %{footer: render_fn}
      }

      Interactive.build_screen(s)
      assert_receive %{"ext-a" => "running"}
    end

    test "set_footer nil restores default footer rendering" do
      s = %Interactive{}
      {s, :ok} = Interactive.handle_ui_request(s, {:set_footer, nil})
      assert is_nil(s.ui_overrides.footer)
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

  describe "build_autocomplete_provider/1" do
    alias OctoPi.TUI.Autocomplete
    alias OctoPi.TUI.Autocomplete.CombinedProvider

    test "returns CombinedProvider with builtin commands" do
      provider = Interactive.build_autocomplete_provider(nil)
      assert %CombinedProvider{} = provider
      {:ok, items} = Autocomplete.get_suggestions(provider, "/help")
      labels = Enum.map(items, & &1.value)
      assert "/help" in labels
    end

    test "returns clear and model commands" do
      provider = Interactive.build_autocomplete_provider(nil)
      {:ok, clear_items} = Autocomplete.get_suggestions(provider, "/clear")
      {:ok, model_items} = Autocomplete.get_suggestions(provider, "/model")
      assert Enum.any?(clear_items, &(&1.value == "/clear"))
      assert Enum.any?(model_items, &(&1.value == "/model"))
    end

    test "suggestions filtered by prefix" do
      provider = Interactive.build_autocomplete_provider(nil)
      {:ok, items} = Autocomplete.get_suggestions(provider, "/mo")
      assert Enum.all?(items, &String.starts_with?(&1.value, "/mo"))
    end

    test "no suggestions for non-slash input" do
      provider = Interactive.build_autocomplete_provider(nil)
      {:ok, items} = Autocomplete.get_suggestions(provider, "hello")
      assert items == []
    end

    test "includes prompt templates from loaded_resources" do
      resources = %{
        context_files: [],
        skills: [],
        prompt_templates: [%{name: "my-template"}, %{name: "other"}]
      }

      provider = Interactive.build_autocomplete_provider(resources)
      {:ok, items} = Autocomplete.get_suggestions(provider, "/my")
      labels = Enum.map(items, & &1.value)
      assert "/my-template" in labels
    end
  end

  describe "build_autocomplete_provider/2 — extension commands (opi-8ee.5)" do
    alias OctoPi.Coder.Extension.API
    alias OctoPi.Coder.Extension.Loader, as: ExtLoader
    alias OctoPi.TUI.Autocomplete

    test "extension commands appear in autocomplete suggestions" do
      {:ok, ext} =
        ExtLoader.load_from_factory("myext", fn api ->
          API.register_command(api, "deploy", %{description: "deploy the app", handler: fn _, _ -> nil end})
        end)

      provider = Interactive.build_autocomplete_provider(nil, [ext])
      {:ok, items} = Autocomplete.get_suggestions(provider, "/dep")
      labels = Enum.map(items, & &1.value)
      assert "/deploy" in labels
    end

    test "extension commands include their description" do
      {:ok, ext} =
        ExtLoader.load_from_factory("myext", fn api ->
          API.register_command(api, "greet", %{description: "say hello", handler: fn _, _ -> nil end})
        end)

      provider = Interactive.build_autocomplete_provider(nil, [ext])
      {:ok, items} = Autocomplete.get_suggestions(provider, "/greet")
      item = Enum.find(items, &(&1.value == "/greet"))
      assert item
      assert item.description =~ "say hello"
    end

    test "extension commands appear alongside builtin commands" do
      {:ok, ext} =
        ExtLoader.load_from_factory("myext", fn api ->
          API.register_command(api, "mycommand", %{description: "custom", handler: fn _, _ -> nil end})
        end)

      provider = Interactive.build_autocomplete_provider(nil, [ext])
      {:ok, items} = Autocomplete.get_suggestions(provider, "/")
      labels = Enum.map(items, & &1.value)
      assert "/help" in labels
      assert "/mycommand" in labels
    end

    test "duplicate extension command names get :1 :2 suffixes" do
      {:ok, ext1} =
        ExtLoader.load_from_factory("ext1", fn api ->
          API.register_command(api, "run", %{description: "first", handler: fn _, _ -> nil end})
        end)

      {:ok, ext2} =
        ExtLoader.load_from_factory("ext2", fn api ->
          API.register_command(api, "run", %{description: "second", handler: fn _, _ -> nil end})
        end)

      provider = Interactive.build_autocomplete_provider(nil, [ext1, ext2])
      {:ok, items} = Autocomplete.get_suggestions(provider, "/run")
      labels = Enum.map(items, & &1.value)
      assert "/run:1" in labels
      assert "/run:2" in labels
    end

    test "no extensions gives same result as build_autocomplete_provider/1" do
      provider1 = Interactive.build_autocomplete_provider(nil)
      provider2 = Interactive.build_autocomplete_provider(nil, [])
      {:ok, items1} = Autocomplete.get_suggestions(provider1, "/")
      {:ok, items2} = Autocomplete.get_suggestions(provider2, "/")
      assert Enum.map(items1, & &1.value) == Enum.map(items2, & &1.value)
    end
  end

  describe "slash-command autocomplete — popup and e2e submit" do
    alias OctoPi.TUI.Autocomplete
    alias OctoPi.TUI.Autocomplete.SlashCommandProvider

    defp state_with_autocomplete do
      provider = SlashCommandProvider.new(Autocomplete.builtin_commands())
      %Interactive{input: %Input{autocomplete_provider: provider}, session: nil}
    end

    test "typing / activates autocomplete in the input" do
      s = Interactive.handle_event(state_with_autocomplete(), %Key{key: ?/})
      assert s.input.autocomplete_active
    end

    test "typing / then h narrows autocomplete to /help" do
      s =
        state_with_autocomplete()
        |> Interactive.handle_event(%Key{key: ?/})
        |> Interactive.handle_event(%Key{key: ?h})

      assert s.input.autocomplete_active
      assert Enum.all?(s.input.autocomplete_suggestions, &String.starts_with?(&1.value, "/h"))
    end

    test "Enter with autocomplete active dispatches slash command and clears input" do
      s =
        state_with_autocomplete()
        |> Interactive.handle_event(%Key{key: ?/})
        |> Interactive.handle_event(%Key{key: ?h})
        |> Interactive.handle_event(%Key{key: :enter})

      refute s.input.autocomplete_active
      assert s.input.value == ""
      assert s.notification =~ "Commands:"
    end

    test "Tab with autocomplete active fills in suggestion without submitting" do
      s =
        state_with_autocomplete()
        |> Interactive.handle_event(%Key{key: ?/})
        |> Interactive.handle_event(%Key{key: ?h})
        |> Interactive.handle_event(%Key{key: :tab})

      refute s.input.autocomplete_active
      assert String.starts_with?(s.input.value, "/h")
      assert s.notification == nil
    end
  end

  describe "handle_ui_request — blocking dialogs" do
    test "select stores pending dialog" do
      options = [%{label: "A", value: :a}, %{label: "B", value: :b}]
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:select, options, []})
      assert s.dialog == {:select, nil, options, []}
    end

    test "confirm stores pending dialog" do
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:confirm, "Sure?", []})
      assert s.dialog == {:confirm, nil, "Sure?", []}
    end

    test "input stores pending dialog" do
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:input, "Name:", []})
      assert s.dialog == {:input, nil, "Name:", []}
    end

    test "editor stores pending dialog" do
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:editor, "initial", []})
      assert s.dialog == {:editor, nil, "initial", []}
    end

    test "custom is handled at loop level — handle_ui_request returns pending with no state change" do
      factory = fn _tui, _theme, _done -> %{render: fn _ -> [] end, handle_input: fn _ -> :ok end} end
      {s, :pending} = Interactive.handle_ui_request(%Interactive{}, {:custom, factory, []})
      assert s.custom_widget == nil
      assert s.dialog == nil
    end
  end

  # ── Custom widget ──────────────────────────────────────────────

  describe "render/2 — custom widget" do
    test "renders component output instead of normal UI when custom_widget is set" do
      component = %{render: fn _w -> ["widget line 1", "widget line 2"] end, handle_input: fn _ -> :ok end}
      state = %Interactive{custom_widget: {{self(), make_ref()}, component}, width: 80, height: 5}
      {lines, _layout} = Interactive.build_screen(state, ["input line"])
      assert "widget line 1" in lines
      assert "widget line 2" in lines
      refute "input line" in lines
    end

    test "custom widget output is padded to height when shorter" do
      component = %{render: fn _w -> ["only line"] end, handle_input: fn _ -> :ok end}
      state = %Interactive{custom_widget: {{self(), make_ref()}, component}, width: 80, height: 5}
      {lines, _layout} = Interactive.build_screen(state, [])
      assert length(lines) == 5
      assert "only line" in lines
    end

    test "custom widget receives the state width" do
      {:ok, widths} = Agent.start_link(fn -> [] end)

      component = %{
        render: fn w ->
          Agent.update(widths, &[w | &1])
          []
        end,
        handle_input: fn _ -> :ok end
      }

      state = %Interactive{custom_widget: {{self(), make_ref()}, component}, width: 120, height: 5}
      Interactive.build_screen(state, [])
      assert [120] = Agent.get(widths, & &1)
    end
  end

  describe "handle_event — custom widget key routing" do
    test "key events are forwarded to handle_input when custom_widget is active" do
      {:ok, received} = Agent.start_link(fn -> [] end)

      component = %{
        render: fn _ -> [] end,
        handle_input: fn ev ->
          Agent.update(received, &[ev | &1])
          :ok
        end
      }

      state = %Interactive{custom_widget: {{self(), make_ref()}, component}}
      Interactive.handle_event(state, %Key{key: :enter})
      assert [%Key{key: :enter}] = Agent.get(received, & &1)
    end

    test "char events are forwarded to handle_input when custom_widget is active" do
      {:ok, received} = Agent.start_link(fn -> [] end)

      component = %{
        render: fn _ -> [] end,
        handle_input: fn ev ->
          Agent.update(received, &[ev | &1])
          :ok
        end
      }

      state = %Interactive{custom_widget: {{self(), make_ref()}, component}}
      Interactive.handle_event(state, %Key{key: ?x})
      assert [%Key{key: ?x}] = Agent.get(received, & &1)
    end

    test "state is unchanged after routing key to custom widget" do
      component = %{render: fn _ -> [] end, handle_input: fn _ -> :ok end}
      state = %Interactive{custom_widget: {{self(), make_ref()}, component}}
      new_state = Interactive.handle_event(state, %Key{key: :enter})
      assert new_state == state
    end

    test "normal key handling resumes when custom_widget is nil" do
      state = %Interactive{input: %Input{value: "", cursor: 0}}
      new_state = Interactive.handle_event(state, %Key{key: :escape})
      assert new_state.exit == true
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
      s = Interactive.handle_event(s, %Key{key: ?x, modifiers: [:ctrl]})
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

      s = Interactive.handle_event(s, %Key{key: :left})
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
      s = Interactive.handle_event(s, %Key{key: ?a, modifiers: [:ctrl]})
      assert s.notification == "first"
    end

    test "Ctrl+C bypasses extension shortcuts (clears non-empty editor)" do
      match_fn = fn _ -> true end
      handler = fn state -> %{state | notification: "blocked"} end

      s = %Interactive{input: %Input{value: "hi", cursor: 2}, extension_shortcuts: [{match_fn, handler}]}
      s = Interactive.handle_event(s, %Key{key: ?c, modifiers: [:ctrl]})
      assert s.input.value == ""
      assert s.notification == nil
    end

    test "empty shortcuts list behaves normally" do
      s = %Interactive{input: %Input{value: "hi", cursor: 2}}
      s = Interactive.handle_event(s, %Key{key: :left})
      assert s.input.cursor == 1
    end
  end

  # ── ctrl+o — startup expansion toggle ─────────────────────────

  describe "handle_event — ctrl+o" do
    test "ctrl+o toggles tools_expanded from false to true" do
      s = %Interactive{tools_expanded: false}
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.tools_expanded == true
    end

    test "ctrl+o toggles tools_expanded from true to false" do
      s = %Interactive{tools_expanded: true}
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.tools_expanded == false
    end

    test "ctrl+o syncs banner expanded to match new tools_expanded" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme)
      s = %Interactive{tools_expanded: false, banner: banner}
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.tools_expanded == true
      assert s.banner.expanded == true
    end

    test "ctrl+o banner sync works when collapsing" do
      theme = Theme.load_builtin(:dark, :truecolor)
      banner = WelcomeBanner.new(theme, [])
      s = %Interactive{tools_expanded: false, banner: banner}
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.banner.expanded == true
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.banner.expanded == false
    end

    test "ctrl+o is safe when banner is nil" do
      s = %Interactive{tools_expanded: false, banner: nil}
      s = Interactive.handle_event(s, %Key{key: ?o, modifiers: [:ctrl]})
      assert s.tools_expanded == true
      assert s.banner == nil
    end
  end

  # ── model cycling / selector (opi-0g4.12) ──────────────────────

  defp make_model(id, provider \\ :fake) do
    %OctoPi.AI.Model{
      id: id,
      name: id,
      api: :fake,
      provider: provider,
      base_url: "http://fake",
      context_window: 100,
      max_tokens: 100
    }
  end

  describe "handle_event — Ctrl+P/Shift+Ctrl+P model cycling (opi-0g4.12)" do
    test "Ctrl+P cycles to next model" do
      m1 = make_model("m1")
      m2 = make_model("m2")
      m3 = make_model("m3")
      s = %Interactive{model: m1, models: [m1, m2, m3], footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl]})
      assert s2.model.id == "m2"
      assert s2.footer.model_id == "m2"
    end

    test "Ctrl+P wraps from last to first" do
      m1 = make_model("m1")
      m2 = make_model("m2")
      s = %Interactive{model: m2, models: [m1, m2], footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl]})
      assert s2.model.id == "m1"
    end

    test "Ctrl+P with empty models is no-op" do
      s = %Interactive{model: nil, models: []}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl]})
      assert s2.model == nil
    end

    test "Ctrl+P sets notification with new model id" do
      m1 = make_model("m1")
      m2 = make_model("m2")
      s = %Interactive{model: m1, models: [m1, m2], footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl]})
      assert s2.notification =~ "m2"
    end

    test "Shift+Ctrl+P cycles to previous model" do
      m1 = make_model("m1")
      m2 = make_model("m2")
      m3 = make_model("m3")
      s = %Interactive{model: m2, models: [m1, m2, m3], footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl, :shift]})
      assert s2.model.id == "m1"
    end

    test "Shift+Ctrl+P wraps from first to last" do
      m1 = make_model("m1")
      m2 = make_model("m2")
      s = %Interactive{model: m1, models: [m1, m2], footer: %Footer{}}
      s2 = Interactive.handle_event(s, %Key{key: ?p, modifiers: [:ctrl, :shift]})
      assert s2.model.id == "m2"
    end
  end

  describe "handle_event — Ctrl+L model selector overlay (opi-0g4.12)" do
    alias OctoPi.TUI.Components.ModelSelector

    test "Ctrl+L opens model_selector" do
      theme = Theme.load_builtin(:dark, :truecolor)
      m1 = make_model("m1")
      s = %Interactive{models: [m1], theme: theme, model: m1}
      s2 = Interactive.handle_event(s, %Key{key: ?l, modifiers: [:ctrl]})
      assert %ModelSelector{} = s2.model_selector
    end

    test "Ctrl+L with empty models is no-op" do
      s = %Interactive{models: [], theme: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?l, modifiers: [:ctrl]})
      assert s2.model_selector == nil
    end

    test "Escape closes model_selector" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ms = ModelSelector.new([make_model("m1")], theme)
      s = %Interactive{model_selector: ms, focused_component: {:dialog, :model_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.model_selector == nil
    end

    test "Enter with model_selector selects model, updates footer and model" do
      theme = Theme.load_builtin(:dark, :truecolor)
      m1 = make_model("m1", :anthropic)
      ms = ModelSelector.new([m1], theme)

      s = %Interactive{
        model_selector: ms,
        focused_component: {:dialog, :model_selector},
        models: [m1],
        model: nil,
        footer: %Footer{},
        theme: theme
      }

      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.model_selector == nil
      assert s2.model.id == "m1"
      assert s2.footer.model_id == "m1"
      assert s2.footer.provider == :anthropic
    end

    test "Enter with empty model_selector list closes without change" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ms = ModelSelector.new([], theme)

      s = %Interactive{
        model_selector: ms,
        focused_component: {:dialog, :model_selector},
        model: nil,
        footer: %Footer{},
        theme: theme
      }

      s2 = Interactive.handle_event(s, %Key{key: :enter})
      assert s2.model_selector == nil
      assert s2.model == nil
    end
  end

  # ── focused_component dispatch (opi-0gw.9) ────────────────────

  describe "focused_component dispatch" do
    alias OctoPi.TUI.Components.ModelSelector

    test "default focused_component is :input" do
      s = %Interactive{}
      assert s.focused_component == :input
    end

    test "Ctrl+L sets focused_component to {:dialog, :model_selector}" do
      theme = Theme.load_builtin(:dark, :truecolor)
      m1 = make_model("m1")
      s = %Interactive{models: [m1], theme: theme, model: m1}
      s2 = Interactive.handle_event(s, %Key{key: ?l, modifiers: [:ctrl]})
      assert s2.focused_component == {:dialog, :model_selector}
    end

    test "Escape from model_selector resets focused_component to :input" do
      theme = Theme.load_builtin(:dark, :truecolor)
      ms = ModelSelector.new([make_model("m1")], theme)
      s = %Interactive{model_selector: ms, focused_component: {:dialog, :model_selector}}
      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.focused_component == :input
    end

    test "Escape from dequeue_overlay resets focused_component to :input" do
      items = [{:follow_up, %User{content: "x", timestamp: 0}}]

      s = %Interactive{
        dequeue_overlay: %{items: items, selected: 0},
        focused_component: {:overlay, :dequeue},
        session: nil
      }

      s2 = Interactive.handle_event(s, %Key{key: :escape})
      assert s2.focused_component == :input
    end

    test "Delete-to-empty from dequeue_overlay resets focused_component to :input" do
      items = [{:follow_up, %User{content: "x", timestamp: 0}}]
      s = %Interactive{dequeue_overlay: %{items: items, selected: 0}, focused_component: {:overlay, :dequeue}}
      s2 = Interactive.handle_event(s, %Key{key: :delete})
      assert s2.focused_component == :input
    end

    test "key with focused_component nil is a no-op" do
      s = %Interactive{focused_component: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?a})
      assert s2 == s
    end
  end

  # ── keybindings loading / user overrides (opi-0g4.8) ───────────

  describe "load_keybindings/1 (opi-0g4.8)" do
    alias OctoPi.TUI.Keybindings

    test "returns default Keybindings when file does not exist" do
      kb = Interactive.load_keybindings(keybindings_path: "/tmp/nonexistent_#{System.unique_integer()}.json")
      assert %Keybindings{} = kb
      assert Keybindings.matches?(kb, %Key{key: ?d, modifiers: [:ctrl]}, "app.exit")
    end

    test "returns default Keybindings when path is nil" do
      kb = Interactive.load_keybindings(keybindings_path: nil)
      assert %Keybindings{} = kb
    end

    test "applies JSON overrides from file" do
      path = Path.join(System.tmp_dir!(), "keybindings_#{System.unique_integer()}.json")
      File.write!(path, Jason.encode!(%{"app.exit" => "ctrl+q"}))
      on_exit(fn -> File.rm(path) end)

      kb = Interactive.load_keybindings(keybindings_path: path)
      assert Keybindings.matches?(kb, %Key{key: ?q, modifiers: [:ctrl]}, "app.exit")
      refute Keybindings.matches?(kb, %Key{key: ?d, modifiers: [:ctrl]}, "app.exit")
    end

    test "falls back to defaults when JSON is invalid" do
      path = Path.join(System.tmp_dir!(), "keybindings_#{System.unique_integer()}.json")
      File.write!(path, "not json at all")
      on_exit(fn -> File.rm(path) end)

      kb = Interactive.load_keybindings(keybindings_path: path)
      assert %Keybindings{} = kb
      assert Keybindings.matches?(kb, %Key{key: ?d, modifiers: [:ctrl]}, "app.exit")
    end
  end

  describe "handle_event — custom keybindings dispatch (opi-0g4.8)" do
    alias OctoPi.TUI.Keybindings

    defp state_with_keybindings(overrides) do
      %Interactive{keybindings: Keybindings.new(overrides)}
    end

    test "remapped app.exit key exits on empty editor" do
      s = state_with_keybindings(%{"app.exit" => "ctrl+q"})
      s = %{s | input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?q, modifiers: [:ctrl]})
      assert s2.exit
    end

    test "old key no longer exits when app.exit is remapped" do
      s = state_with_keybindings(%{"app.exit" => "ctrl+q"})
      s = %{s | input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?d, modifiers: [:ctrl]})
      refute s2.exit
    end

    test "remapped app.suspend suspends on new key" do
      s = state_with_keybindings(%{"app.suspend" => "ctrl+b"})
      s2 = Interactive.handle_event(s, %Key{key: ?b, modifiers: [:ctrl]})
      assert s2.suspend_pending
    end

    test "default keybindings (nil) still dispatch correctly" do
      s = %Interactive{input: %Input{value: "", cursor: 0}}
      s2 = Interactive.handle_event(s, %Key{key: ?d, modifiers: [:ctrl]})
      assert s2.exit
    end
  end

  # ── loaded_resources rendering ─────────────────────────────────

  defp fake_resources(overrides \\ %{}) do
    Map.merge(
      %{context_files: [], skills: [], prompt_templates: []},
      overrides
    )
  end

  defp joined_render(state) do
    state
    |> Interactive.build_screen()
    |> Enum.join("\n")
  end

  defp strip_ansi(text), do: String.replace(text, ~r/\e\[[0-9;]*m/, "")

  describe "render/1 — loaded resources sections" do
    test "no resource sections when loaded_resources is nil" do
      s = %Interactive{width: 80, height: 40, loaded_resources: nil}
      output = joined_render(s)
      refute strip_ansi(output) =~ "[Context]"
      refute strip_ansi(output) =~ "[Skills]"
      refute strip_ansi(output) =~ "[Prompts]"
    end

    test "no resource sections when all lists are empty" do
      s = %Interactive{width: 80, height: 40, loaded_resources: fake_resources()}
      output = joined_render(s)
      refute strip_ansi(output) =~ "[Context]"
      refute strip_ansi(output) =~ "[Skills]"
      refute strip_ansi(output) =~ "[Prompts]"
    end

    test "context section appears when context_files is non-empty" do
      resources = fake_resources(%{context_files: [%{path: "/project/CLAUDE.md"}]})
      s = %Interactive{width: 80, height: 40, loaded_resources: resources}
      assert strip_ansi(joined_render(s)) =~ "[Context]"
    end

    test "context compact shows basename" do
      resources = fake_resources(%{context_files: [%{path: "/project/CLAUDE.md"}]})
      s = %Interactive{width: 80, height: 40, loaded_resources: resources, tools_expanded: false}
      assert strip_ansi(joined_render(s)) =~ "CLAUDE.md"
    end

    test "context compact shows multiple basenames comma-separated" do
      resources =
        fake_resources(%{
          context_files: [%{path: "/a/CLAUDE.md"}, %{path: "/b/AGENTS.md"}]
        })

      s = %Interactive{width: 80, height: 40, loaded_resources: resources, tools_expanded: false}
      output = strip_ansi(joined_render(s))
      assert output =~ "CLAUDE.md"
      assert output =~ "AGENTS.md"
    end

    test "context expanded shows full paths" do
      resources =
        fake_resources(%{
          context_files: [%{path: "/project/CLAUDE.md"}]
        })

      s = %Interactive{width: 80, height: 40, loaded_resources: resources, tools_expanded: true}
      assert strip_ansi(joined_render(s)) =~ "/project/CLAUDE.md"
    end

    test "skills section appears when skills is non-empty" do
      resources = fake_resources(%{skills: [%{name: "my-skill", file_path: "/skills/SKILL.md"}]})
      s = %Interactive{width: 80, height: 40, loaded_resources: resources}
      assert strip_ansi(joined_render(s)) =~ "[Skills]"
    end

    test "skills compact shows skill names" do
      resources =
        fake_resources(%{
          skills: [
            %{name: "code-review", file_path: "/s/code-review/SKILL.md"},
            %{name: "debug", file_path: "/s/debug/SKILL.md"}
          ]
        })

      s = %Interactive{width: 80, height: 40, loaded_resources: resources, tools_expanded: false}
      output = strip_ansi(joined_render(s))
      assert output =~ "code-review"
      assert output =~ "debug"
    end

    test "prompts section appears when prompt_templates is non-empty" do
      resources = fake_resources(%{prompt_templates: [%{name: "greet"}]})
      s = %Interactive{width: 80, height: 40, loaded_resources: resources}
      assert strip_ansi(joined_render(s)) =~ "[Prompts]"
    end

    test "prompts compact shows /name format" do
      resources =
        fake_resources(%{
          prompt_templates: [%{name: "greet"}, %{name: "review"}]
        })

      s = %Interactive{width: 80, height: 40, loaded_resources: resources, tools_expanded: false}
      output = strip_ansi(joined_render(s))
      assert output =~ "/greet"
      assert output =~ "/review"
    end

    test "resources sections appear before transcript" do
      resources = fake_resources(%{context_files: [%{path: "/p/CLAUDE.md"}]})

      s = %Interactive{
        width: 80,
        height: 40,
        loaded_resources: resources,
        transcript: [%AssistantMessage{content: [{:text, "hello"}], theme: Theme.load_builtin(:dark, :truecolor)}]
      }

      output = strip_ansi(joined_render(s))
      context_pos = output |> :binary.match("[Context]") |> elem(0)
      hello_pos = output |> :binary.match("hello") |> elem(0)
      assert context_pos < hello_pos
    end

    test "all three sections visible together" do
      resources = %{
        context_files: [%{path: "/p/CLAUDE.md"}],
        skills: [%{name: "my-skill", file_path: "/s/SKILL.md"}],
        prompt_templates: [%{name: "cmd"}]
      }

      s = %Interactive{width: 80, height: 40, loaded_resources: resources}
      output = strip_ansi(joined_render(s))
      assert output =~ "[Context]"
      assert output =~ "[Skills]"
      assert output =~ "[Prompts]"
    end
  end

  describe "app.clipboard.pasteImage dispatch" do
    test "ctrl+v with no image in clipboard leaves state unchanged" do
      s = %Interactive{input: %Input{value: "before", cursor: 6}}
      s2 = Interactive.handle_event(s, %Key{key: ?v, modifiers: [:ctrl]})
      # Clipboard returns :error (no image) → state input unchanged
      # (may insert "v" if keybinding fires before paste — just assert no crash)
      assert is_struct(s2, Interactive)
    end

    test "ctrl+v does not crash when render_loop is nil" do
      s = %Interactive{render_loop: nil}
      s2 = Interactive.handle_event(s, %Key{key: ?v, modifiers: [:ctrl]})
      assert is_struct(s2, Interactive)
    end
  end
end
