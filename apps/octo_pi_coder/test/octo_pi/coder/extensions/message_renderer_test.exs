defmodule OctoPi.Coder.Extensions.MessageRendererTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Context
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.MessageRenderer

  defp ext_with_messages do
    {:ok, entries} = Agent.start_link(fn -> [] end)

    factory = fn api ->
      api =
        API.bind_core(api, %{
          append_entry: fn entry ->
            Agent.update(entries, fn acc -> [entry | acc] end)
            :ok
          end
        })

      MessageRenderer.init(api)
    end

    {:ok, ext} = Loader.load_from_factory("message-renderer", factory)
    {ext, entries}
  end

  defp ctx, do: Context.new(%{cwd: "/tmp"})

  describe "init/1" do
    test "registers a 'status-update' message renderer" do
      {ext, _} = ext_with_messages()
      assert Map.has_key?(ext.message_renderers, "status-update")
    end

    test "registers a 'status' command" do
      {ext, _} = ext_with_messages()
      assert Map.has_key?(ext.commands, "status")
    end

    test "'status' has expected description" do
      {ext, _} = ext_with_messages()
      assert ext.commands["status"].description =~ "status"
    end

    test "registers no tools" do
      {ext, _} = ext_with_messages()
      assert ext.tools == %{}
    end

    test "registers no event handlers" do
      {ext, _} = ext_with_messages()
      assert ext.handlers == %{}
    end
  end

  describe "status-update renderer" do
    test "returns a string" do
      {ext, _} = ext_with_messages()
      renderer = ext.message_renderers["status-update"]
      result = renderer.(%{content: "hello", details: %{level: "info"}}, %{})
      assert is_binary(result)
    end

    test "includes the message content" do
      {ext, _} = ext_with_messages()
      renderer = ext.message_renderers["status-update"]
      result = renderer.(%{content: "deployment finished", details: %{level: "info"}}, %{})
      assert result =~ "deployment finished"
    end

    test "includes the level label" do
      {ext, _} = ext_with_messages()
      renderer = ext.message_renderers["status-update"]
      result = renderer.(%{content: "oops", details: %{level: "error"}}, %{})
      assert result =~ "ERROR" or result =~ "error"
    end
  end

  describe "/status command" do
    test "appends a status-update entry" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("hello world", ctx())
      [entry] = Agent.get(entries, & &1)
      assert entry.custom_type == "status-update"
    end

    test "entry content contains the message text" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("hello world", ctx())
      [entry] = Agent.get(entries, & &1)
      assert entry.content =~ "hello world"
    end

    test "defaults to info level" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("some message", ctx())
      [entry] = Agent.get(entries, & &1)
      assert entry.details.level == "info"
    end

    test "sets warn level when args start with 'warn'" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("warn something went wrong", ctx())
      [entry] = Agent.get(entries, & &1)
      assert entry.details.level == "warn"
    end

    test "sets error level when args start with 'error'" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("error boom", ctx())
      [entry] = Agent.get(entries, & &1)
      assert entry.details.level == "error"
    end

    test "content does not include the level prefix" do
      {ext, entries} = ext_with_messages()
      ext.commands["status"].handler.("warn something went wrong", ctx())
      [entry] = Agent.get(entries, & &1)
      refute entry.content =~ "warn "
    end
  end
end
