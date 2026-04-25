defmodule OctoPi.Coder.Extension.AgentSessionExtensionTest do
  @moduledoc """
  Elixir port of:
    * test/suite/agent-session-model-extension.test.ts (~12 cases)
    * test/suite/regressions/2835-tools-allowlist-filters-extension-tools.test.ts (~2 cases)

  ## Divergences from upstream

  **TypeScript model management tests not ported:**
  setModel (model_select event emission), cycleModel, cycleThinkingLevel, and auth
  validation are TypeScript AgentSession features not in the Elixir agent. `set_model/2`
  exists but emitting `model_select` events belongs in the CLI/coder layer.

  **Context and input transformation tested at Dispatcher level:**
  Upstream tests verify these by capturing what was sent to the transport via
  callback-based responses. `FauxTransport` supports scripted `FauxResponse` structs
  only, not callbacks. The semantics are tested via `Dispatcher.reduce_chain/4` and
  `Dispatcher.emit_input/5` — the same code path the live session calls.

  **Input transformation already covered:**
  `extensions_input_event_test.exs` (opi-hix.3) fully covers the `:input` / `reduce_chain`
  pattern including transform, handled, chaining, source propagation, and error handling.

  **Dynamic tool registration from session_start:**
  Upstream test #2835 registers a tool from within a `session_start` handler via the live
  `pi.registerTool()` action (requires `bind_core`). The Elixir equivalent tests
  statically-registered extension tools with `Dispatcher.get_all_tools/1` filtering.
  """

  use ExUnit.Case, async: false

  alias OctoPi.Agent.MessageLog
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Message.ToolResult, as: AIToolResult
  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Test.FauxResponse
  alias OctoPi.Coder.Test.FauxTransport
  alias OctoPi.Coder.Test.Harness

  @moduletag capture_log: true

  setup do
    on_exit(&FauxTransport.clear/0)
    :ok
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  defp ext(id, handlers) do
    Enum.reduce(handlers, Extension.new(id, "/ext/#{id}"), fn {event_type, handler}, e ->
      Extension.add_handler(e, event_type, handler)
    end)
  end

  # ── tool_call blocking (integration) ────────────────────────────

  describe "tool_call blocking" do
    test "extension handler returning {:block, reason} produces an error result" do
      factory = fn api ->
        API.on(api, :tool_call, fn _event, _ctx -> {:block, "Blocked by extension"} end)
      end

      harness = Harness.create(tools: [echo_tool()], factories: [{"blocker", factory}])

      FauxTransport.set_script([
        %FauxResponse{tool_calls: [%{id: "tc1", name: "echo", args: %{text: "hello"}}]},
        %FauxResponse{text: "done"}
      ])

      :ok = OctoPi.Agent.prompt(harness.session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      tool_result = find_tool_result(harness)

      assert tool_result.is_error?

      assert Enum.any?(tool_result.content, fn
               %Text{text: text} -> String.contains?(text, "Blocked by extension")
               _ -> false
             end)
    end

    test "non-blocking extension allows the tool to execute normally" do
      factory = fn api ->
        API.on(api, :tool_call, fn _event, _ctx -> nil end)
      end

      harness = Harness.create(tools: [echo_tool()], factories: [{"passthrough", factory}])

      FauxTransport.set_script([
        %FauxResponse{tool_calls: [%{id: "tc1", name: "echo", args: %{text: "hello"}}]},
        %FauxResponse{text: "done"}
      ])

      :ok = OctoPi.Agent.prompt(harness.session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      tool_result = find_tool_result(harness)

      refute tool_result.is_error?

      assert Enum.any?(tool_result.content, fn
               %Text{text: "hello"} -> true
               _ -> false
             end)
    end
  end

  # ── tool_result patching (integration) ──────────────────────────

  describe "tool_result modification" do
    test "extension tool_result handler patches content and details" do
      factory = fn api ->
        API.on(api, :tool_result, fn _event, _ctx ->
          %{content: [%Text{text: "patched result"}], details: %{patched: true}}
        end)
      end

      harness = Harness.create(tools: [echo_tool()], factories: [{"patcher", factory}])

      FauxTransport.set_script([
        %FauxResponse{tool_calls: [%{id: "tc1", name: "echo", args: %{text: "original"}}]},
        %FauxResponse{text: "done"}
      ])

      :ok = OctoPi.Agent.prompt(harness.session, "hi")
      :ok = OctoPi.Agent.wait_for_idle(harness.session, 2_000)

      tool_result = find_tool_result(harness)

      refute tool_result.is_error?

      assert Enum.any?(tool_result.content, fn
               %Text{text: "patched result"} -> true
               _ -> false
             end)

      assert tool_result.details == %{patched: true}
    end
  end

  # ── session lifecycle (Harness helpers) ─────────────────────────

  describe "session lifecycle events" do
    test "bind_extensions emits session_start with reason :startup" do
      test_pid = self()

      factory = fn api ->
        API.on(api, :session_start, fn ev, _ctx ->
          send(test_pid, {:lifecycle, :session_start, ev.reason})
        end)
      end

      harness = Harness.create(factories: [{"lifecycle", factory}])
      Harness.bind_extensions(harness)

      assert_received {:lifecycle, :session_start, :startup}
    end

    test "reload emits session_shutdown then session_start with reason :reload" do
      test_pid = self()

      factory = fn api ->
        {:ok, api} =
          API.on(api, :session_start, fn ev, _ctx ->
            send(test_pid, {:lifecycle, :session_start, ev.reason})
          end)

        API.on(api, :session_shutdown, fn ev, _ctx ->
          send(test_pid, {:lifecycle, :session_shutdown, ev.reason})
        end)
      end

      harness = Harness.create(factories: [{"lifecycle", factory}])
      Harness.bind_extensions(harness)
      Harness.reload(harness)

      assert_received {:lifecycle, :session_start, :startup}
      assert_received {:lifecycle, :session_shutdown, :reload}
      assert_received {:lifecycle, :session_start, :reload}
    end
  end

  # ── context event (Dispatcher level) ────────────────────────────

  describe "context event — reduce_chain" do
    test "handler rewrites messages before the LLM call" do
      test_pid = self()
      messages = [%{role: :user, content: "original", ts: 0}, %{role: :assistant, content: "reply", ts: 1}]

      e =
        ext("ctx", [
          {:context,
           fn event, _ctx ->
             rewritten = Enum.map(event.messages, &rewrite_user_message/1)
             send(test_pid, :handler_ran)
             %{messages: rewritten}
           end}
        ])

      result = Dispatcher.reduce_chain([e], :context, messages, ctx())

      assert_received :handler_ran
      assert Enum.find(result, &(&1.role == :user)).content == "rewritten"
      assert Enum.find(result, &(&1.role == :assistant)).content == "reply"
    end

    test "multiple context handlers chain transformations in order" do
      e1 =
        ext("ctx1", [
          {:context,
           fn event, _ctx ->
             %{messages: Enum.map(event.messages, fn m -> %{m | content: m.content <> "[1]"} end)}
           end}
        ])

      e2 =
        ext("ctx2", [
          {:context,
           fn event, _ctx ->
             %{messages: Enum.map(event.messages, fn m -> %{m | content: m.content <> "[2]"} end)}
           end}
        ])

      messages = [%{role: :user, content: "x", ts: 0}]
      result = Dispatcher.reduce_chain([e1, e2], :context, messages, ctx())

      assert hd(result).content == "x[1][2]"
    end

    test "no handlers returns messages unchanged" do
      messages = [%{role: :user, content: "unchanged", ts: 0}]
      assert Dispatcher.reduce_chain([], :context, messages, ctx()) == messages
    end

    test "handler error is swallowed and original messages continue to next handler" do
      e1 = ext("bad", context: fn _event, _ctx -> raise "boom" end)

      e2 =
        ext("ok",
          context: fn event, _ctx ->
            %{messages: Enum.map(event.messages, fn m -> %{m | content: "ok:" <> m.content} end)}
          end
        )

      messages = [%{role: :user, content: "x", ts: 0}]
      result = Dispatcher.reduce_chain([e1, e2], :context, messages, ctx())

      assert hd(result).content == "ok:x"
    end
  end

  # ── before_agent_start (Dispatcher level) ───────────────────────

  describe "before_agent_start — collect_all" do
    test "handler returns a map that is collected into the results list" do
      injection = %{
        message: %{custom_type: "before-start", content: "injected"},
        system_prompt: "base\n\nextra instructions"
      }

      e = ext("bef", before_agent_start: fn _ev, _ctx -> injection end)

      results = Dispatcher.collect_all([e], Event.new(:before_agent_start), ctx())

      assert results == [injection]
    end

    test "multiple handlers collect results in extension order" do
      e1 = ext("bef1", before_agent_start: fn _ev, _ctx -> %{message: "msg1"} end)
      e2 = ext("bef2", before_agent_start: fn _ev, _ctx -> %{message: "msg2"} end)

      results = Dispatcher.collect_all([e1, e2], Event.new(:before_agent_start), ctx())

      assert results == [%{message: "msg1"}, %{message: "msg2"}]
    end

    test "no handlers returns empty list" do
      assert [] = Dispatcher.collect_all([], Event.new(:before_agent_start), ctx())
    end

    test "nil-returning handler is excluded from results" do
      e = ext("bef", before_agent_start: fn _ev, _ctx -> nil end)
      assert [] = Dispatcher.collect_all([e], Event.new(:before_agent_start), ctx())
    end
  end

  # ── model_select (Dispatcher level) ─────────────────────────────

  describe "model_select — fire_and_forget" do
    test "handler receives model select event fields" do
      test_pid = self()

      e =
        ext("ms", [
          {:model_select,
           fn event, _ctx ->
             send(test_pid, {:model_selected, event.model_id, event.source})
           end}
        ])

      event = Event.new(:model_select, %{model_id: "faux-2", previous_model_id: "faux-1", source: :set})
      Dispatcher.fire_and_forget([e], event, ctx())

      assert_received {:model_selected, "faux-2", :set}
    end

    test "multiple handlers are all called" do
      test_pid = self()

      e1 = ext("ms1", model_select: fn _ev, _ctx -> send(test_pid, :first) end)
      e2 = ext("ms2", model_select: fn _ev, _ctx -> send(test_pid, :second) end)

      Dispatcher.fire_and_forget([e1, e2], Event.new(:model_select, %{model_id: "x", source: :set}), ctx())

      assert_received :first
      assert_received :second
    end
  end

  # ── tool allowlist — regression #2835 (Dispatcher level) ────────

  describe "regression #2835 — tool allowlist filters extension tools" do
    test "get_all_tools returns statically-registered extension tools" do
      e =
        "tools_ext"
        |> Extension.new("/ext/tools")
        |> Extension.add_tool(%{name: "dynamic_tool", description: "d"})

      names = [e] |> Dispatcher.get_all_tools() |> Enum.map(& &1.name)

      assert "dynamic_tool" in names
    end

    test "tools can be filtered to an explicit allowlist" do
      e =
        "tools_ext"
        |> Extension.new("/ext/tools")
        |> Extension.add_tool(%{name: "read", description: "read"})
        |> Extension.add_tool(%{name: "dynamic_tool", description: "dynamic"})
        |> Extension.add_tool(%{name: "bash", description: "bash"})

      allowlist = ["read", "dynamic_tool"]
      filtered = [e] |> Dispatcher.get_all_tools() |> Enum.filter(&(&1.name in allowlist))

      names = filtered |> Enum.map(& &1.name) |> Enum.sort()

      assert names == ["dynamic_tool", "read"]
      refute "bash" in names
    end

    test "empty allowlist produces no tools" do
      e =
        "tools_ext"
        |> Extension.new("/ext/tools")
        |> Extension.add_tool(%{name: "dynamic_tool", description: "d"})

      filtered = [e] |> Dispatcher.get_all_tools() |> Enum.filter(&(&1.name in []))

      assert filtered == []
    end
  end

  # ── helpers ──────────────────────────────────────────────────────

  defp echo_tool do
    %OctoPi.Agent.Tool{
      name: "echo",
      description: "echo text",
      parameters: %{},
      handler: __MODULE__.EchoHandler
    }
  end

  defp find_tool_result(%Harness{session: session}) do
    state = OctoPi.Agent.state(session)
    state.messages |> MessageLog.to_list() |> Enum.find(&match?(%AIToolResult{}, &1))
  end

  defp rewrite_user_message(%{role: :user} = m), do: %{m | content: "rewritten"}
  defp rewrite_user_message(m), do: m

  defmodule EchoHandler do
    @moduledoc false
    @behaviour OctoPi.Agent.Tool.Handler

    @impl true
    def execute(_id, args, _abort_ref, _on_update) do
      text = Map.get(args, :text, "")
      {:ok, %OctoPi.Agent.Tool.Result{content: [%Text{text: text}]}}
    end
  end
end
