defmodule OctoPi.Coder.Extension.DispatcherTest do
  use ExUnit.Case, async: true

  # Many tests here intentionally raise inside handlers to exercise
  # error-isolation semantics; the warnings they log are expected.
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event

  @moduletag capture_log: true

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  defp ext(id, handlers) do
    Enum.reduce(handlers, Extension.new(id, "/ext/#{id}"), fn {event_type, handler}, ext ->
      Extension.add_handler(ext, event_type, handler)
    end)
  end

  # --- fire_and_forget ---

  describe "fire_and_forget/3" do
    test "calls all handlers across extensions" do
      test_pid = self()
      e1 = ext("a", session_start: fn _e, _c -> send(test_pid, {:called, :a}) end)
      e2 = ext("b", session_start: fn _e, _c -> send(test_pid, {:called, :b}) end)

      assert :ok =
               Dispatcher.fire_and_forget(
                 [e1, e2],
                 Event.new(:session_start, %{reason: :new}),
                 ctx()
               )

      assert_received {:called, :a}
      assert_received {:called, :b}
    end

    test "ignores handler return values" do
      e = ext("a", session_start: fn _e, _c -> :some_value end)
      assert :ok = Dispatcher.fire_and_forget([e], Event.new(:session_start), ctx())
    end

    test "skips extensions without handlers for event" do
      e = ext("a", turn_start: fn _e, _c -> flunk("should not be called") end)
      assert :ok = Dispatcher.fire_and_forget([e], Event.new(:session_start), ctx())
    end

    test "continues after handler error" do
      test_pid = self()

      e =
        ext("a", [
          {:session_start, fn _e, _c -> raise "boom" end},
          {:session_start, fn _e, _c -> send(test_pid, :second_called) end}
        ])

      assert :ok = Dispatcher.fire_and_forget([e], Event.new(:session_start), ctx())
      assert_received :second_called
    end

    test "emits telemetry on handler error" do
      ref =
        :telemetry_test.attach_event_handlers(self(), [
          [:octo_pi_coder, :extension, :handler_error]
        ])

      e = ext("a", session_start: fn _e, _c -> raise "kaboom" end)
      Dispatcher.fire_and_forget([e], Event.new(:session_start), ctx())

      assert_received {[:octo_pi_coder, :extension, :handler_error], ^ref, %{}, meta}
      assert meta.extension_id == "a"
      assert meta.event_type == :session_start
      assert meta.error =~ "kaboom"
    end

    test "executes handlers in registration order" do
      test_pid = self()

      e =
        ext("a", [
          {:turn_start, fn _e, _c -> send(test_pid, 1) end},
          {:turn_start, fn _e, _c -> send(test_pid, 2) end},
          {:turn_start, fn _e, _c -> send(test_pid, 3) end}
        ])

      Dispatcher.fire_and_forget(
        [e],
        Event.new(:turn_start, %{turn_index: 0, timestamp: 0}),
        ctx()
      )

      assert_received 1
      assert_received 2
      assert_received 3
    end
  end

  # --- halt_on_result ---

  describe "halt_on_result/3" do
    test "returns :ok when no handler cancels" do
      e = ext("a", session_before_switch: fn _e, _c -> nil end)
      assert :ok = Dispatcher.halt_on_result([e], Event.new(:session_before_switch), ctx())
    end

    test "short-circuits on {:cancel, reason}" do
      test_pid = self()

      e =
        ext("a", [
          {:session_before_switch, fn _e, _c -> {:cancel, "dirty repo"} end},
          {:session_before_switch, fn _e, _c -> send(test_pid, :should_not_reach) end}
        ])

      assert {:cancel, "dirty repo"} =
               Dispatcher.halt_on_result([e], Event.new(:session_before_switch), ctx())

      refute_received :should_not_reach
    end

    test "continues past nil returns" do
      test_pid = self()

      e1 = ext("a", session_before_fork: fn _e, _c -> nil end)
      e2 = ext("b", session_before_fork: fn _e, _c -> send(test_pid, :reached) end)

      Dispatcher.halt_on_result([e1, e2], Event.new(:session_before_fork), ctx())
      assert_received :reached
    end

    test "continues past handler errors" do
      e1 = ext("a", session_before_compact: fn _e, _c -> raise "nope" end)
      e2 = ext("b", session_before_compact: fn _e, _c -> {:cancel, "reason"} end)

      assert {:cancel, "reason"} =
               Dispatcher.halt_on_result([e1, e2], Event.new(:session_before_compact), ctx())
    end

    test "{:override, value} halts and surfaces the value" do
      e = ext("a", session_before_compact: fn _e, _c -> {:override, %{summary: "stub"}} end)

      assert {:override, %{summary: "stub"}} =
               Dispatcher.halt_on_result([e], Event.new(:session_before_compact), ctx())
    end

    test "first halting result wins regardless of channel" do
      test_pid = self()

      e =
        ext("a", [
          {:session_before_compact, fn _e, _c -> {:override, :first} end},
          {:session_before_compact,
           fn _e, _c ->
             send(test_pid, :should_not_reach)
             {:cancel, :second}
           end}
        ])

      assert {:override, :first} =
               Dispatcher.halt_on_result([e], Event.new(:session_before_compact), ctx())

      refute_received :should_not_reach
    end
  end

  # --- reduce_chain ---

  describe "reduce_chain/4" do
    test "folds handlers over accumulator" do
      e =
        ext("a", [
          {:context, fn _e, _c -> %{messages: [:added_by_a]} end},
          {:context, fn _e, _c -> %{messages: [:added_by_a, :added_by_b]} end}
        ])

      result = Dispatcher.reduce_chain([e], :context, [], ctx())
      assert result == [:added_by_a, :added_by_b]
    end

    test "nil return preserves accumulator" do
      e = ext("a", context: fn _e, _c -> nil end)
      assert [1, 2] = Dispatcher.reduce_chain([e], :context, [1, 2], ctx())
    end

    test "passes current accumulator in event payload" do
      test_pid = self()

      e =
        ext("a", [
          {:context,
           fn event, _c ->
             send(test_pid, {:saw, event.messages})
             %{messages: event.messages ++ [:transformed]}
           end}
        ])

      result = Dispatcher.reduce_chain([e], :context, [:original], ctx())
      assert_received {:saw, [:original]}
      assert result == [:original, :transformed]
    end

    test "error skips handler, preserves accumulator" do
      e =
        ext("a", [
          {:context, fn _e, _c -> raise "fail" end},
          {:context, fn _e, _c -> %{messages: [:from_second]} end}
        ])

      assert [:from_second] = Dispatcher.reduce_chain([e], :context, [:init], ctx())
    end
  end

  # --- mutate_in_place ---

  describe "mutate_in_place/3" do
    test "threads event through handlers, updating input" do
      e =
        ext("a", [
          {:tool_call,
           fn event, _c ->
             %{event | input: Map.put(event.input, :sanitized, true)}
           end}
        ])

      event =
        Event.new(:tool_call, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{command: "rm -rf /"}
        })

      assert {:ok, result} = Dispatcher.mutate_in_place([e], event, ctx())
      assert result.input.sanitized == true
      assert result.input.command == "rm -rf /"
    end

    test "blocks on {:block, reason}" do
      e = ext("a", tool_call: fn _e, _c -> {:block, "not allowed"} end)
      event = Event.new(:tool_call, %{tool_call_id: "tc1", tool_name: "bash", input: %{}})
      assert {:block, "not allowed"} = Dispatcher.mutate_in_place([e], event, ctx())
    end

    test "later handler sees earlier mutations" do
      test_pid = self()

      e =
        ext("a", [
          {:tool_call,
           fn event, _c ->
             %{event | input: Map.put(event.input, :step1, true)}
           end},
          {:tool_call,
           fn event, _c ->
             send(test_pid, {:saw_step1, event.input[:step1]})
             %{event | input: Map.put(event.input, :step2, true)}
           end}
        ])

      event = Event.new(:tool_call, %{tool_call_id: "tc1", tool_name: "bash", input: %{}})
      {:ok, result} = Dispatcher.mutate_in_place([e], event, ctx())
      assert_received {:saw_step1, true}
      assert result.input.step1
      assert result.input.step2
    end

    test "error skips handler, preserves event state" do
      e =
        ext("a", [
          {:tool_call, fn _e, _c -> raise "boom" end},
          {:tool_call, fn event, _c -> %{event | input: Map.put(event.input, :ok, true)} end}
        ])

      event = Event.new(:tool_call, %{tool_call_id: "tc1", tool_name: "bash", input: %{}})
      {:ok, result} = Dispatcher.mutate_in_place([e], event, ctx())
      assert result.input.ok
    end
  end

  # --- patch_merge ---

  describe "patch_merge/3" do
    test "merges partial patches from handlers" do
      e =
        ext("a", [
          {:tool_result, fn _e, _c -> %{content: "patched content"} end},
          {:tool_result, fn _e, _c -> %{is_error: true} end}
        ])

      event =
        Event.new(:tool_result, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{},
          content: "original",
          is_error: false,
          details: nil
        })

      assert {:ok, patches} = Dispatcher.patch_merge([e], event, ctx())
      assert patches.content == "patched content"
      assert patches.is_error == true
    end

    test "later patches override earlier ones for same key" do
      e =
        ext("a", [
          {:tool_result, fn _e, _c -> %{content: "first"} end},
          {:tool_result, fn _e, _c -> %{content: "second"} end}
        ])

      event =
        Event.new(:tool_result, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{},
          content: "",
          is_error: false,
          details: nil
        })

      {:ok, patches} = Dispatcher.patch_merge([e], event, ctx())
      assert patches.content == "second"
    end

    test "returns :unchanged when no handler patches" do
      e = ext("a", tool_result: fn _e, _c -> nil end)

      event =
        Event.new(:tool_result, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{},
          content: "",
          is_error: false,
          details: nil
        })

      assert :unchanged = Dispatcher.patch_merge([e], event, ctx())
    end

    test "error skips handler" do
      e =
        ext("a", [
          {:tool_result, fn _e, _c -> raise "nope" end},
          {:tool_result, fn _e, _c -> %{content: "survived"} end}
        ])

      event =
        Event.new(:tool_result, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{},
          content: "",
          is_error: false,
          details: nil
        })

      {:ok, patches} = Dispatcher.patch_merge([e], event, ctx())
      assert patches.content == "survived"
    end
  end

  # --- first_result ---

  describe "first_result/3" do
    test "returns first non-nil result" do
      e1 = ext("a", user_bash: fn _e, _c -> nil end)
      e2 = ext("b", user_bash: fn _e, _c -> %{result: "custom output"} end)

      event = Event.new(:user_bash, %{command: "ls", cwd: "/tmp", exclude_from_context: false})
      assert %{result: "custom output"} = Dispatcher.first_result([e1, e2], event, ctx())
    end

    test "returns nil when no handler returns a result" do
      e = ext("a", user_bash: fn _e, _c -> nil end)
      event = Event.new(:user_bash, %{command: "ls", cwd: "/tmp", exclude_from_context: false})
      assert nil == Dispatcher.first_result([e], event, ctx())
    end

    test "stops after first non-nil" do
      test_pid = self()

      e =
        ext("a", [
          {:user_bash, fn _e, _c -> %{result: "done"} end},
          {:user_bash, fn _e, _c -> send(test_pid, :should_not_reach) end}
        ])

      event = Event.new(:user_bash, %{command: "ls", cwd: "/tmp", exclude_from_context: false})
      Dispatcher.first_result([e], event, ctx())
      refute_received :should_not_reach
    end

    test "error skips handler, continues" do
      e =
        ext("a", [
          {:user_bash, fn _e, _c -> raise "err" end},
          {:user_bash, fn _e, _c -> %{result: "ok"} end}
        ])

      event = Event.new(:user_bash, %{command: "ls", cwd: "/tmp", exclude_from_context: false})
      assert %{result: "ok"} = Dispatcher.first_result([e], event, ctx())
    end
  end

  # --- collect_all ---

  describe "collect_all/3" do
    test "accumulates results from all handlers" do
      e1 = ext("a", resources_discover: fn _e, _c -> %{skill_paths: ["/a/skill"]} end)
      e2 = ext("b", resources_discover: fn _e, _c -> %{prompt_paths: ["/b/prompt"]} end)

      event = Event.new(:resources_discover, %{cwd: "/tmp", reason: :startup})
      results = Dispatcher.collect_all([e1, e2], event, ctx())
      assert length(results) == 2
      assert %{skill_paths: ["/a/skill"]} in results
      assert %{prompt_paths: ["/b/prompt"]} in results
    end

    test "filters out nil results" do
      e =
        ext("a", [
          {:resources_discover, fn _e, _c -> nil end},
          {:resources_discover, fn _e, _c -> %{skill_paths: ["/x"]} end}
        ])

      event = Event.new(:resources_discover, %{cwd: "/tmp", reason: :startup})
      results = Dispatcher.collect_all([e], event, ctx())
      assert length(results) == 1
    end

    test "returns empty list when no handlers match" do
      e = ext("a", [])
      event = Event.new(:resources_discover, %{cwd: "/tmp", reason: :startup})
      assert [] = Dispatcher.collect_all([e], event, ctx())
    end
  end

  # --- emit/3 (auto-dispatch by pattern) ---

  describe "emit/3" do
    test "auto-dispatches fire_and_forget" do
      test_pid = self()
      e = ext("a", session_start: fn _e, _c -> send(test_pid, :called) end)
      Dispatcher.emit([e], Event.new(:session_start, %{reason: :new}), ctx())
      assert_received :called
    end

    test "auto-dispatches halt_on_result" do
      e = ext("a", session_before_switch: fn _e, _c -> {:cancel, "nope"} end)
      assert {:cancel, "nope"} = Dispatcher.emit([e], Event.new(:session_before_switch), ctx())
    end

    test "auto-dispatches mutate_in_place" do
      e = ext("a", tool_call: fn event, _c -> %{event | input: %{safe: true}} end)
      event = Event.new(:tool_call, %{tool_call_id: "tc1", tool_name: "bash", input: %{}})
      assert {:ok, result} = Dispatcher.emit([e], event, ctx())
      assert result.input.safe
    end

    test "auto-dispatches patch_merge" do
      e = ext("a", tool_result: fn _e, _c -> %{content: "patched"} end)

      event =
        Event.new(:tool_result, %{
          tool_call_id: "tc1",
          tool_name: "bash",
          input: %{},
          content: "",
          is_error: false,
          details: nil
        })

      assert {:ok, %{content: "patched"}} = Dispatcher.emit([e], event, ctx())
    end

    test "auto-dispatches first_result" do
      e = ext("a", user_bash: fn _e, _c -> %{result: "out"} end)
      event = Event.new(:user_bash, %{command: "ls", cwd: "/tmp", exclude_from_context: false})
      assert %{result: "out"} = Dispatcher.emit([e], event, ctx())
    end

    test "auto-dispatches collect_all" do
      e = ext("a", resources_discover: fn _e, _c -> %{skill_paths: ["/x"]} end)
      event = Event.new(:resources_discover, %{cwd: "/tmp", reason: :startup})
      assert [%{skill_paths: ["/x"]}] = Dispatcher.emit([e], event, ctx())
    end
  end

  # --- introspection ---

  describe "get_extension_paths/1" do
    test "returns all extension paths" do
      e1 = Extension.new("a", "/ext/a")
      e2 = Extension.new("b", "/ext/b")
      assert ["/ext/a", "/ext/b"] = Dispatcher.get_extension_paths([e1, e2])
    end
  end

  describe "get_all_tools/1" do
    test "returns deduplicated tools across extensions" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_tool(%{name: "t1", description: "d"})
      e2 = "b" |> Extension.new("/b") |> Extension.add_tool(%{name: "t2", description: "d"})

      tools = Dispatcher.get_all_tools([e1, e2])
      assert length(tools) == 2
      assert Enum.map(tools, & &1.name) == ["t1", "t2"]
    end

    test "first extension wins on name conflict" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_tool(%{name: "t", description: "from a"})
      e2 = "b" |> Extension.new("/b") |> Extension.add_tool(%{name: "t", description: "from b"})

      tools = Dispatcher.get_all_tools([e1, e2])
      assert length(tools) == 1
      assert hd(tools).description == "from a"
    end
  end

  describe "get_tool_definition/2" do
    test "finds tool by name" do
      e = "a" |> Extension.new("/a") |> Extension.add_tool(%{name: "mytool", description: "d"})
      assert %{name: "mytool"} = Dispatcher.get_tool_definition([e], "mytool")
    end

    test "returns nil for unknown tool" do
      assert nil == Dispatcher.get_tool_definition([Extension.new("a", "/a")], "nope")
    end
  end

  describe "get_all_commands/1" do
    test "returns deduplicated commands with extension id" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_command("cmd1", %{description: "d1"})
      e2 = "b" |> Extension.new("/b") |> Extension.add_command("cmd2", %{description: "d2"})

      cmds = Dispatcher.get_all_commands([e1, e2])
      assert length(cmds) == 2
      assert {"cmd1", %{description: "d1"}, "a"} in cmds
    end

    test "first extension wins on name conflict" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_command("dup", %{description: "a's"})
      e2 = "b" |> Extension.new("/b") |> Extension.add_command("dup", %{description: "b's"})

      cmds = Dispatcher.get_all_commands([e1, e2])
      assert length(cmds) == 1
      assert {"dup", %{description: "a's"}, "a"} in cmds
    end
  end

  describe "get_command/2" do
    test "finds command by name" do
      e = "a" |> Extension.new("/a") |> Extension.add_command("run", %{description: "run it"})
      assert {%{description: "run it"}, "a"} = Dispatcher.get_command([e], "run")
    end

    test "returns nil for unknown command" do
      assert nil == Dispatcher.get_command([Extension.new("a", "/a")], "nope")
    end
  end

  describe "get_message_renderer/2" do
    test "finds renderer by type" do
      renderer = fn _type, _data -> "rendered" end
      e = "a" |> Extension.new("/a") |> Extension.add_message_renderer("custom", renderer)
      assert ^renderer = Dispatcher.get_message_renderer([e], "custom")
    end

    test "returns nil for unknown type" do
      assert nil == Dispatcher.get_message_renderer([Extension.new("a", "/a")], "nope")
    end
  end

  describe "has_handlers?/2" do
    test "true when handlers registered" do
      e = ext("a", session_start: fn _, _ -> nil end)
      assert Dispatcher.has_handlers?([e], :session_start)
    end

    test "false when no handlers" do
      e = Extension.new("a", "/a")
      refute Dispatcher.has_handlers?([e], :session_start)
    end
  end

  describe "get_command_diagnostics/1" do
    test "reports conflicts" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_command("dup", %{})
      e2 = "b" |> Extension.new("/b") |> Extension.add_command("dup", %{})

      diags = Dispatcher.get_command_diagnostics([e1, e2])
      assert [%{name: "dup", extensions: ["a", "b"]}] = diags
    end

    test "no conflicts returns empty" do
      e1 = "a" |> Extension.new("/a") |> Extension.add_command("c1", %{})
      e2 = "b" |> Extension.new("/b") |> Extension.add_command("c2", %{})

      assert [] = Dispatcher.get_command_diagnostics([e1, e2])
    end
  end
end
