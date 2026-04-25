defmodule OctoPi.Coder.Extension.ExtensionsRunnerTest do
  @moduledoc """
  Elixir port of upstream extensions-runner.test.ts.

  In pi-mono this layer is the `ExtensionRunner` class, which wraps a
  list of `Extension` structs and a shared `RuntimeState`. In Elixir the
  equivalent is `Dispatcher` (for event routing and introspection) plus
  `RuntimeState` (for flag values) plus `API` (for provider queuing).

  Differences from upstream documented per describe block.
  """

  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension
  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Dispatcher
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.ProviderConfig
  alias OctoPi.Coder.Extension.RuntimeState

  defp ext(id, factory) do
    {:ok, extension} = Loader.load_from_factory(id, factory)
    extension
  end

  defp ctx, do: %Context{cwd: "/tmp"}

  # ── tool collection ─────────────────────────────────────────────

  describe "tool collection" do
    test "collects tools from multiple extensions" do
      make_tool = fn name -> %{name: name, description: "test"} end

      e1 = ext("ext-a", fn api -> {:ok, elem(API.register_tool(api, make_tool.("tool_a")), 1)} end)
      e2 = ext("ext-b", fn api -> {:ok, elem(API.register_tool(api, make_tool.("tool_b")), 1)} end)

      tools = Dispatcher.get_all_tools([e1, e2])
      assert length(tools) == 2
      assert tools |> Enum.map(& &1.name) |> Enum.sort() == ["tool_a", "tool_b"]
    end

    test "first-wins when two extensions register the same tool name" do
      e1 = ext("first", fn api -> {:ok, elem(API.register_tool(api, %{name: "shared", description: "first"}), 1)} end)
      e2 = ext("second", fn api -> {:ok, elem(API.register_tool(api, %{name: "shared", description: "second"}), 1)} end)

      tools = Dispatcher.get_all_tools([e1, e2])
      assert length(tools) == 1
      assert hd(tools).description == "first"
    end
  end

  # ── command collection ───────────────────────────────────────────

  describe "command collection" do
    test "get_registered_commands returns all commands with invocation names" do
      cmd = %{description: "Test command", handler: fn _ctx -> :ok end}

      e1 = ext("cmd-a", fn api -> {:ok, elem(API.register_command(api, "cmd-a", cmd), 1)} end)
      e2 = ext("cmd-b", fn api -> {:ok, elem(API.register_command(api, "cmd-b", cmd), 1)} end)

      entries = Dispatcher.get_registered_commands([e1, e2])
      assert length(entries) == 2

      names = entries |> Enum.map(& &1.name) |> Enum.sort()
      assert names == ["cmd-a", "cmd-b"]

      invocations = entries |> Enum.map(& &1.invocation_name) |> Enum.sort()
      assert invocations == ["cmd-a", "cmd-b"]
    end

    test "get_command_by_invocation finds a unique command" do
      cmd = %{description: "My command", handler: fn _ctx -> :ok end}
      e = ext("ext", fn api -> {:ok, elem(API.register_command(api, "my-cmd", cmd), 1)} end)

      assert {found_cmd, "ext"} = Dispatcher.get_command_by_invocation([e], "my-cmd")
      assert found_cmd.description == "My command"

      assert nil == Dispatcher.get_command_by_invocation([e], "not-exists")
    end

    test "duplicate command names get :1 / :2 invocation suffixes in insertion order" do
      cmd_a = %{description: "First command", handler: fn _ctx -> :ok end}
      cmd_b = %{description: "Second command", handler: fn _ctx -> :ok end}

      e1 = ext("cmd-a", fn api -> {:ok, elem(API.register_command(api, "shared-cmd", cmd_a), 1)} end)
      e2 = ext("cmd-b", fn api -> {:ok, elem(API.register_command(api, "shared-cmd", cmd_b), 1)} end)

      entries = Dispatcher.get_registered_commands([e1, e2])
      assert length(entries) == 2

      assert Enum.map(entries, & &1.name) == ["shared-cmd", "shared-cmd"]
      assert Enum.map(entries, & &1.invocation_name) == ["shared-cmd:1", "shared-cmd:2"]

      assert {c1, _} = Dispatcher.get_command_by_invocation([e1, e2], "shared-cmd:1")
      assert c1.description == "First command"

      assert {c2, _} = Dispatcher.get_command_by_invocation([e1, e2], "shared-cmd:2")
      assert c2.description == "Second command"
    end
  end

  # ── message renderers ────────────────────────────────────────────

  describe "message renderers" do
    test "get_message_renderer returns the renderer for a known type" do
      renderer = fn _msg, _opts -> "" end
      e = ext("ext", fn api -> {:ok, elem(API.register_message_renderer(api, "my-type", renderer), 1)} end)

      found = Dispatcher.get_message_renderer([e], "my-type")
      assert found == renderer
    end

    test "get_message_renderer returns nil for unknown type" do
      e = Extension.new("ext", "/ext")
      assert nil == Dispatcher.get_message_renderer([e], "not-there")
    end
  end

  # ── handler introspection ────────────────────────────────────────

  describe "hasHandlers" do
    test "returns true when extension has a handler for the event type" do
      e = ext("ext", fn api -> API.on(api, :tool_call, fn _ev, _ctx -> nil end) end)
      assert Dispatcher.has_handlers?([e], :tool_call)
    end

    test "returns false when no extension has a handler for the event type" do
      e = ext("ext", fn api -> API.on(api, :tool_call, fn _ev, _ctx -> nil end) end)
      refute Dispatcher.has_handlers?([e], :agent_end)
    end
  end

  # ── flag collection ──────────────────────────────────────────────

  describe "flag collection" do
    test "get_all_flags collects flags from extensions" do
      spec = %{description: "My flag", default: false}
      e = ext("ext", fn api -> {:ok, elem(API.register_flag(api, "my-flag", spec), 1)} end)

      flags = Dispatcher.get_all_flags([e])
      assert Enum.any?(flags, fn {name, _} -> name == "my-flag" end)
    end

    test "first-wins when two extensions register the same flag name" do
      s1 = %{description: "first", default: true}
      s2 = %{description: "second", default: false}

      e1 = ext("a-first", fn api -> {:ok, elem(API.register_flag(api, "shared-flag", s1), 1)} end)
      e2 = ext("b-second", fn api -> {:ok, elem(API.register_flag(api, "shared-flag", s2), 1)} end)

      flags = Dispatcher.get_all_flags([e1, e2])
      {_, spec} = Enum.find(flags, fn {n, _} -> n == "shared-flag" end)
      assert spec.description == "first"
    end

    test "flag values are stored and retrieved via RuntimeState" do
      state = RuntimeState.new()
      state = RuntimeState.set_flag(state, "--test-flag", true)
      assert RuntimeState.get_flag(state, "--test-flag") == true
      assert RuntimeState.get_flag(state, "--missing", :default) == :default
    end
  end

  # ── shortcut collection ──────────────────────────────────────────
  #
  # Upstream pi-mono tests shortcut conflict detection against built-in
  # keybindings (reserved vs non-reserved). That logic lives in
  # ExtensionRunner.getShortcuts(keybindings) and depends on the TUI
  # keybinding registry, which is not available here. These tests cover
  # basic shortcut registration and collection only; conflict detection
  # is deferred.

  describe "shortcut collection" do
    test "get_all_shortcuts returns shortcuts from extensions" do
      spec = %{description: "My shortcut", handler: fn _ctx -> :ok end}
      e = ext("ext", fn api -> {:ok, elem(API.register_shortcut(api, "ctrl+shift+x", spec), 1)} end)

      shortcuts = Dispatcher.get_all_shortcuts([e])
      assert Enum.any?(shortcuts, fn {key, _} -> key == "ctrl+shift+x" end)
    end

    test "get_all_shortcuts collects from multiple extensions" do
      spec = fn key -> %{description: key, handler: fn _ctx -> :ok end} end

      e1 = ext("ext-a", fn api -> {:ok, elem(API.register_shortcut(api, "ctrl+1", spec.("one")), 1)} end)
      e2 = ext("ext-b", fn api -> {:ok, elem(API.register_shortcut(api, "ctrl+2", spec.("two")), 1)} end)

      shortcuts = Dispatcher.get_all_shortcuts([e1, e2])
      keys = Enum.map(shortcuts, &elem(&1, 0))
      assert "ctrl+1" in keys
      assert "ctrl+2" in keys
    end
  end

  # ── before_agent_start (collect_all) ────────────────────────────
  #
  # Upstream: runner.emitBeforeAgentStart chains ctx.getSystemPrompt()
  # through handlers so each sees the previous handler's update.
  # Elixir: Dispatcher.collect_all returns the raw list of handler
  # return values; caller is responsible for reduction. The context
  # is NOT updated between handler calls — that is a caller concern.

  describe "before_agent_start (collect_all)" do
    test "collect_all accumulates return values from multiple handlers" do
      e1 =
        ext("ext-a", fn api ->
          API.on(api, :before_agent_start, fn _ev, _ctx -> %{extra: "a"} end)
        end)

      e2 =
        ext("ext-b", fn api ->
          API.on(api, :before_agent_start, fn _ev, _ctx -> %{extra: "b"} end)
        end)

      event = %{type: :before_agent_start, messages: []}
      results = Dispatcher.collect_all([e1, e2], event, ctx())

      assert length(results) == 2
      assert %{extra: "a"} in results
      assert %{extra: "b"} in results
    end

    test "collect_all returns empty list when no handlers registered" do
      e = Extension.new("ext", "/ext")
      event = %{type: :before_agent_start, messages: []}
      assert [] == Dispatcher.collect_all([e], event, ctx())
    end
  end

  # ── tool_result (patch_merge) ────────────────────────────────────
  #
  # Upstream: emitToolResult chains content by having each handler see
  # the modified event from the previous handler (reduce semantics).
  # Elixir: Dispatcher.patch_merge collects all patches and merges them
  # with Map.merge (later handler wins per key). Callers that need full
  # chaining should use reduce_chain on :tool_result explicitly.

  describe "tool_result (patch_merge)" do
    test "patches from multiple handlers are merged" do
      e1 =
        ext("ext-a", fn api ->
          API.on(api, :tool_result, fn _ev, _ctx -> %{is_error: false} end)
        end)

      e2 =
        ext("ext-b", fn api ->
          API.on(api, :tool_result, fn _ev, _ctx -> %{details: %{source: "ext-b"}} end)
        end)

      event = %{type: :tool_result, content: [%{type: "text", text: "base"}], is_error: true}
      result = Dispatcher.patch_merge([e1, e2], event, ctx())

      assert {:ok, patch} = result
      assert patch.is_error == false
      assert patch.details == %{source: "ext-b"}
    end

    test "later handler wins for the same key" do
      e1 =
        ext("ext-a", fn api ->
          API.on(api, :tool_result, fn _ev, _ctx -> %{is_error: false} end)
        end)

      e2 =
        ext("ext-b", fn api ->
          API.on(api, :tool_result, fn _ev, _ctx -> %{is_error: true} end)
        end)

      event = %{type: :tool_result, content: []}
      {:ok, patch} = Dispatcher.patch_merge([e1, e2], event, ctx())
      assert patch.is_error == true
    end

    test "returns :unchanged when no handlers are registered" do
      e = Extension.new("ext", "/ext")
      event = %{type: :tool_result, content: []}
      assert :unchanged == Dispatcher.patch_merge([e], event, ctx())
    end
  end

  # ── context creation ─────────────────────────────────────────────

  describe "context creation" do
    test "Context.signal holds an abort reference" do
      ref = make_ref()
      ctx = %Context{cwd: "/tmp", signal: ref}
      assert ctx.signal == ref
    end

    test "Context.signal is nil by default" do
      ctx = %Context{cwd: "/tmp"}
      assert ctx.signal == nil
    end
  end

  # ── error handling ───────────────────────────────────────────────

  describe "error handling" do
    test "handler error does not crash dispatch (fire_and_forget swallows)" do
      e =
        ext("throws", fn api ->
          API.on(api, :agent_start, fn _ev, _ctx -> raise "Handler error!" end)
        end)

      event = %{type: :agent_start}
      assert :ok == Dispatcher.fire_and_forget([e], event, ctx())
    end

    test "handler error is skipped in collect_all — does not crash" do
      e =
        ext("throws", fn api ->
          API.on(api, :before_agent_start, fn _ev, _ctx -> raise "oops" end)
        end)

      event = %{type: :before_agent_start, messages: []}
      results = Dispatcher.collect_all([e], event, ctx())
      assert results == []
    end
  end

  # ── provider registration ────────────────────────────────────────

  describe "provider registration" do
    test "register_provider queues the provider before bind" do
      api = API.new("test-ext")
      config = %ProviderConfig{id: "my-provider", base_url: "https://p.test/v1", api: :openai_completions}
      {:ok, api} = API.register_provider(api, config)

      assert [{:register, ^config}] = API.pending_providers(api)
    end

    test "unregister_provider queues removal before bind" do
      api = API.new("test-ext")
      config = %ProviderConfig{id: "my-provider", base_url: "https://p.test/v1", api: :openai_completions}
      {:ok, api} = API.register_provider(api, config)
      {:ok, api} = API.unregister_provider(api, "my-provider")

      assert [{:register, _}, {:unregister, "my-provider"}] = API.pending_providers(api)
    end

    test "multiple register calls accumulate in pending queue" do
      api = API.new("test-ext")
      c1 = %ProviderConfig{id: "p1", base_url: "https://p1.test/v1", api: :openai_completions}
      c2 = %ProviderConfig{id: "p2", base_url: "https://p2.test/v1", api: :openai_completions}

      {:ok, api} = API.register_provider(api, c1)
      {:ok, api} = API.register_provider(api, c2)

      assert length(API.pending_providers(api)) == 2
    end
  end
end
