defmodule OctoPi.Coder.Extensions.CustomFooterTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extension.UIContext
  alias OctoPi.Coder.Extensions.CustomFooter

  defp ext_with_state do
    {:ok, state} = Agent.start_link(fn -> %{enabled: false} end)
    {:ok, ext} = Loader.load_from_factory("custom-footer", fn api -> CustomFooter.init(api, state) end)
    {ext, state}
  end

  defp ui_ctx(footer_calls, notify_calls) do
    ui = %UIContext{
      set_footer: fn component -> Agent.update(footer_calls, fn acc -> [component | acc] end) end,
      notify: fn msg -> Agent.update(notify_calls, fn acc -> [msg | acc] end) end
    }

    Context.new(%{cwd: "/tmp", has_ui?: true, ui: ui})
  end

  describe "init/2" do
    test "registers a 'footer' command" do
      {ext, _} = ext_with_state()
      assert Map.has_key?(ext.commands, "footer")
    end

    test "'footer' has expected description" do
      {ext, _} = ext_with_state()
      assert ext.commands["footer"].description =~ "footer"
    end

    test "registers no tools" do
      {ext, _} = ext_with_state()
      assert ext.tools == %{}
    end

    test "registers no event handlers" do
      {ext, _} = ext_with_state()
      assert ext.handlers == %{}
    end
  end

  describe "/footer command toggle" do
    test "first call enables footer by calling set_footer with a render fn" do
      {:ok, footer_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(footer_calls, notify_calls)

      {ext, _} = ext_with_state()
      ext.commands["footer"].handler.("", ctx)

      [component] = Agent.get(footer_calls, & &1)
      assert is_function(component, 1)
    end

    test "second call disables footer by calling set_footer with nil" do
      {:ok, footer_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(footer_calls, notify_calls)

      {ext, _} = ext_with_state()
      ext.commands["footer"].handler.("", ctx)
      ext.commands["footer"].handler.("", ctx)

      [last | _] = Agent.get(footer_calls, & &1)
      assert is_nil(last)
    end

    test "third call re-enables footer with a render fn" do
      {:ok, footer_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(footer_calls, notify_calls)

      {ext, _} = ext_with_state()
      ext.commands["footer"].handler.("", ctx)
      ext.commands["footer"].handler.("", ctx)
      ext.commands["footer"].handler.("", ctx)

      [last | _] = Agent.get(footer_calls, & &1)
      assert is_function(last, 1)
    end

    test "notifies user on each toggle" do
      {:ok, footer_calls} = Agent.start_link(fn -> [] end)
      {:ok, notify_calls} = Agent.start_link(fn -> [] end)
      ctx = ui_ctx(footer_calls, notify_calls)

      {ext, _} = ext_with_state()
      ext.commands["footer"].handler.("", ctx)

      assert length(Agent.get(notify_calls, & &1)) == 1
    end
  end
end
