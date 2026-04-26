defmodule OctoPi.Agent.ExtensionRegistrationTest do
  use ExUnit.Case, async: false

  alias OctoPi.Agent.Extension
  alias OctoPi.Agent.ExtensionRunner
  alias OctoPi.Agent.SessionManager
  alias OctoPi.Agent.TestSupport.EchoTool
  alias OctoPi.Agent.TestSupport.FakeTransport
  alias OctoPi.AI.Content.Text
  alias OctoPi.AI.Event, as: AIEvent
  alias OctoPi.AI.Message.Assistant
  alias OctoPi.AI.Model
  alias OctoPi.AI.Usage

  @moduletag capture_log: true

  # ── Extension modules ─────────────────────────────────────────────────────────

  defmodule ToolRegisteringExtension do
    @moduledoc false
    @behaviour Extension

    @impl true
    def on_event(:session_start, _payload, ctx) do
      ctx.register_tool.(EchoTool.tool())
      :ok
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  defmodule CommandRegisteringExtension do
    @moduledoc false
    @behaviour Extension

    def key, do: {__MODULE__, :last_args}

    @impl true
    def on_event(:session_start, _payload, ctx) do
      ctx.register_command.("hello", fn args ->
        :persistent_term.put(key(), args)
        :ok
      end)

      :ok
    end

    def on_event(_type, _payload, _ctx), do: :ok
  end

  # ── Helpers ───────────────────────────────────────────────────────────────────

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

  defp start_session(opts \\ []) do
    {:ok, pid} = OctoPi.Agent.start_session(Keyword.merge([model: model(), transport: FakeTransport], opts))
    pid
  end

  # ── tool_registry ─────────────────────────────────────────────────────────────

  describe "register_tool/2" do
    test "adds tool to tool_registry" do
      session = start_session()
      :ok = OctoPi.Agent.register_tool(session, EchoTool.tool())

      state = OctoPi.Agent.state(session)
      assert Map.has_key?(state.tool_registry, "echo")
    end
  end

  describe "set_active_tools/2" do
    test "populates state.tools for known tool names" do
      session = start_session()
      :ok = OctoPi.Agent.register_tool(session, EchoTool.tool())
      :ok = OctoPi.Agent.set_active_tools(session, ["echo"])

      state = OctoPi.Agent.state(session)
      assert Enum.any?(state.tools, &(&1.name == "echo"))
    end

    test "skips unknown tool names" do
      session = start_session()
      :ok = OctoPi.Agent.set_active_tools(session, ["not_a_real_tool"])

      state = OctoPi.Agent.state(session)
      assert state.tools == []
    end

    test "get_active_tool_names returns names of active tools" do
      session = start_session()
      :ok = OctoPi.Agent.register_tool(session, EchoTool.tool())
      :ok = OctoPi.Agent.set_active_tools(session, ["echo"])

      assert OctoPi.Agent.get_active_tool_names(session) == ["echo"]
    end
  end

  # ── session_start hook ────────────────────────────────────────────────────────

  describe "session_start hook" do
    test "fires on session creation and extension can register a tool" do
      session = start_session(extensions: [ToolRegisteringExtension])

      state = OctoPi.Agent.state(session)
      assert Map.has_key?(state.tool_registry, "echo")
    end

    test "tool registered during session_start is found by set_active_tools" do
      session = start_session(extensions: [ToolRegisteringExtension])
      :ok = OctoPi.Agent.set_active_tools(session, ["echo"])

      state = OctoPi.Agent.state(session)
      assert Enum.any?(state.tools, &(&1.name == "echo"))
    end
  end

  # ── command registry ──────────────────────────────────────────────────────────

  describe "command registry" do
    test "register_command adds to ExtensionRunner; get_commands returns it" do
      {:ok, runner} = ExtensionRunner.start_link(session_pid: self())
      :ok = ExtensionRunner.register_command(runner, "test", fn _args -> :ok end)

      cmds = ExtensionRunner.get_commands(runner)
      assert Map.has_key?(cmds, "test")
    end

    test "session get_commands delegates to ExtensionRunner" do
      session = start_session(extensions: [CommandRegisteringExtension])

      cmds = OctoPi.Agent.get_commands(session)
      assert Map.has_key?(cmds, "hello")
    end

    test "session get_commands returns empty map when no extension_runner" do
      session = start_session()
      assert OctoPi.Agent.get_commands(session) == %{}
    end
  end

  # ── slash-command dispatch ────────────────────────────────────────────────────

  describe "slash-command dispatch" do
    test "prompt with /commandname calls registered handler instead of adding a message" do
      :persistent_term.put(CommandRegisteringExtension.key(), nil)
      session = start_session(extensions: [CommandRegisteringExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "/hello world")

      refute_receive {:octo_pi_agent_event, _}, 200

      assert :persistent_term.get(CommandRegisteringExtension.key()) == "world"
    end

    test "unknown slash command falls through as a regular prompt" do
      FakeTransport.set_script([stop_turn()])
      session = start_session(extensions: [CommandRegisteringExtension])
      OctoPi.Agent.subscribe(session, self(), :async)

      :ok = OctoPi.Agent.prompt(session, "/unknown arg")
      :ok = OctoPi.Agent.wait_for_idle(session, 2_000)

      state = OctoPi.Agent.state(session)
      ctx = SessionManager.build_session_context(state.session_manager)
      assert ctx.messages != []
    end
  end
end
