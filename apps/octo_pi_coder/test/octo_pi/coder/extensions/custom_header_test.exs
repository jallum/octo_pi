defmodule OctoPi.Coder.Extensions.CustomHeaderTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Event
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.CustomHeader

  defp load_ext do
    {:ok, ext} = Loader.load_from_factory("custom-header", &CustomHeader.init/1)
    ext
  end

  defp no_ui_ctx, do: Context.new(%{cwd: "/tmp"})

  defp ui_ctx(header_calls, notify_calls) do
    ui = %UIContext{
      set_header: fn component -> Agent.update(header_calls, fn acc -> [component | acc] end) end,
      notify: fn msg -> Agent.update(notify_calls, fn acc -> [msg | acc] end) end
    }

    Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
  end

  describe "init/1" do
    test "registers a session_start handler" do
      ext = load_ext()
      assert Map.has_key?(ext.handlers, :session_start)
    end

    test "registers a 'builtin-header' command" do
      ext = load_ext()
      assert Map.has_key?(ext.commands, "builtin-header")
    end

    test "'builtin-header' has expected description" do
      ext = load_ext()
      assert ext.commands["builtin-header"].description =~ "header"
    end

    test "registers no tools" do
      assert load_ext().tools == %{}
    end
  end

  describe "session_start handler" do
    test "calls set_header when has_ui? is true" do
      {:ok, header_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(header_calls, notify_calls)
      ext = load_ext()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx)
      assert length(Agent.get(header_calls, & &1)) == 1
    end

    test "set_header receives a non-nil component" do
      {:ok, header_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(header_calls, notify_calls)
      ext = load_ext()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), ctx)
      [component] = Agent.get(header_calls, & &1)
      assert component
    end

    test "does not call set_header when has_ui? is false" do
      ext = load_ext()
      handler = hd(ext.handlers[:session_start])
      handler.(Event.new(:session_start, %{reason: :startup}), no_ui_ctx())
    end
  end

  describe "/builtin-header command" do
    test "calls set_header with nil to restore built-in header" do
      {:ok, header_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(header_calls, notify_calls)
      ext = load_ext()
      ext.commands["builtin-header"].handler.("", ctx)
      [component] = Agent.get(header_calls, & &1)
      assert is_nil(component)
    end

    test "notifies user after restoring" do
      {:ok, header_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(header_calls, notify_calls)
      ext = load_ext()
      ext.commands["builtin-header"].handler.("", ctx)
      assert length(Agent.get(notify_calls, & &1)) == 1
    end
  end
end
