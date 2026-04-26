defmodule OctoPi.Agent.ExtensionHooksTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Event
  alias OctoPi.Agent.Extension
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.TestSupport.EchoTool
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Message.ToolResult
  alias OctoPi.AI.Message.User
  alias OctoPi.AI.Model
  alias OctoPi.AI.ToolCall
  alias OctoPi.AI.Usage

  @moduletag capture_log: true

  # ── SpyTransport ──────────────────────────────────────────────────────────────

  defmodule SpyTransport do
    @moduledoc false
    @behaviour OctoPi.Agent.Transport

    @key {__MODULE__, :last_context}

    def last_context, do: :persistent_term.get(@key, nil)
    def clear, do: :persistent_term.put(@key, nil)

    @impl true
    def stream(model, context, opts) do
      :persistent_term.put(@key, context)
      FakeTransport.stream(model, context, opts)
    end
  end

  # ── Extension modules ─────────────────────────────────────────────────────────

  defmodule ContextInjectingExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:context, %{messages: msgs}, _ctx) do
      marker = %User{content: "[context-hook-marker]", timestamp: 0}
      {:ok, %{messages: msgs ++ [marker]}}
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule ToolCallCancelExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:tool_call, _payload, _ctx), do: {:cancel, :blocked_by_extension}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule ToolCallArgsExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:tool_call, %{args: args}, _ctx) do
      {:ok, %{args: Map.put(args, "text", "modified-by-extension")}}
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule ToolResultModExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:tool_result, _payload, _ctx) do
      {:ok, %{result: %OctoPi.Agent.Tool.Result{content: [%Text{text: "overridden-by-extension"}]}}}
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule InputCancelExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:input, _payload, _ctx), do: {:cancel, :blocked_by_extension}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule InputTransformExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:input, _payload, _ctx), do: {:ok, %{text: "transformed-by-extension"}}
    def on_event(_type, _payload, _ctx), do: :ok
  end

  # ── Setup / helpers ───────────────────────────────────────────────────────────

  setup do
    on_exit(&FakeTransport.clear/0)
    SpyTransport.clear()
    :ok
  end

  defp model do
    %Model{
      id: "fake-model",
      name: "fake",
      api: :fake_api,
      provider: :fake,
      base_url: "http://fake",
      context_window: nil,
      max_tokens: 100
    }
  end

  defp stop_turn do
    msg = %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [%Text{text: "ok"}],
      stop_reason: :stop,
      usage: %Usage{}
    }

    [%AIEvent.Done{reason: :stop, message: msg}]
  end

  defp tool_call_turn(call) do
    msg = %Assistant{
      api: :fake_api,
      provider: :fake,
      model: "fake-model",
      timestamp: 0,
      content: [call],
      stop_reason: :tool_use,
      usage: %Usage{}
    }

    [%AIEvent.Done{reason: :tool_use, message: msg}]
  end

  defp start_session_with(opts) do
    {:ok, pid} =
      OctoPi.Agent.start_session(Keyword.merge([model: model(), transport: FakeTransport], opts))

    pid
  end

  # ── :context hook ─────────────────────────────────────────────────────────────

  describe ":context hook" do
    test "modifying messages changes what the transport receives" do
      FakeTransport.set_script([stop_turn()])

      {:ok, session} =
        OctoPi.Agent.start_session(
          model: model(),
          transport: SpyTransport,
          extensions: [ContextInjectingExtension]
        )

      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "hello")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      ctx = SpyTransport.last_context()
      assert ctx

      assert Enum.any?(ctx.messages, fn
               %User{content: "[context-hook-marker]"} -> true
               _ -> false
             end)
    end
  end

  # ── :tool_call hook ───────────────────────────────────────────────────────────

  describe ":tool_call hook" do
    test "cancel hook produces an error ToolResult without calling the handler" do
      call = %ToolCall{id: "c1", name: "echo", arguments: %{"text" => "hello"}}

      FakeTransport.set_script([
        tool_call_turn(call),
        stop_turn()
      ])

      session = start_session_with(tools: [EchoTool.tool()], extensions: [ToolCallCancelExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "use echo")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      tr = Enum.find(ctx.messages, &match?(%ToolResult{}, &1))
      assert tr
      assert tr.is_error? == true
    end

    test "args modification is seen by the handler" do
      call = %ToolCall{id: "c2", name: "echo", arguments: %{"text" => "original"}}

      FakeTransport.set_script([
        tool_call_turn(call),
        stop_turn()
      ])

      session = start_session_with(tools: [EchoTool.tool()], extensions: [ToolCallArgsExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "use echo")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      tr = Enum.find(ctx.messages, &match?(%ToolResult{}, &1))
      assert tr
      assert tr.is_error? == false
      text = Enum.map_join(tr.content, "", fn %Text{text: t} -> t end)
      assert String.contains?(text, "modified-by-extension")
    end
  end

  # ── :tool_result hook ─────────────────────────────────────────────────────────

  describe ":tool_result hook" do
    test "modification changes the ToolResult appended to session_manager" do
      call = %ToolCall{id: "c3", name: "echo", arguments: %{"text" => "original"}}

      FakeTransport.set_script([
        tool_call_turn(call),
        stop_turn()
      ])

      session = start_session_with(tools: [EchoTool.tool()], extensions: [ToolResultModExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "use echo")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      tr = Enum.find(ctx.messages, &match?(%ToolResult{}, &1))
      assert tr
      text = Enum.map_join(tr.content, "", fn %Text{text: t} -> t end)
      assert String.contains?(text, "overridden-by-extension")
    end
  end

  # ── :input hook ───────────────────────────────────────────────────────────────

  describe ":input hook" do
    test "cancel discards the prompt and no run starts" do
      session = start_session_with(extensions: [InputCancelExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "hello")

      refute_receive {:octo_pi_agent_event, %Event.AgentStart{}}, 300

      state = OctoPi.Agent.state(session)
      refute state.is_streaming?
    end

    test "text transformation modifies the prompt before appending" do
      FakeTransport.set_script([stop_turn()])

      session = start_session_with(extensions: [InputTransformExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "original text")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)

      user_msg = Enum.find(ctx.messages, &match?(%User{}, &1))
      assert user_msg
      assert user_msg.content == "transformed-by-extension"
    end
  end

  # ── nil extension_runner ──────────────────────────────────────────────────────

  describe "nil extension_runner" do
    test "all hooks are skipped gracefully when no extensions are registered" do
      call = %ToolCall{id: "c4", name: "echo", arguments: %{"text" => "hi"}}

      FakeTransport.set_script([
        tool_call_turn(call),
        stop_turn()
      ])

      session = start_session_with(tools: [EchoTool.tool()])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "use echo")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      assert_receive {:octo_pi_agent_event, %Event.AgentEnd{reason: :stop}}, 2_000
    end
  end
end
