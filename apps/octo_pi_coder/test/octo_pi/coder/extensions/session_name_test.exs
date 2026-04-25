defmodule OctoPi.Coder.Extensions.SessionNameTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.SessionName

  defp ext_with_store do
    {:ok, agent} = Agent.start_link(fn -> nil end)

    factory = fn api ->
      api =
        API.bind_core(api, %{
          set_session_name: fn name -> Agent.update(agent, fn _ -> name end) end,
          get_session_name: fn -> Agent.get(agent, & &1) end
        })

      SessionName.init(api)
    end

    {:ok, ext} = Loader.load_from_factory("session-name", factory)
    {ext, agent}
  end

  describe "init/1" do
    test "registers a command named 'session-name'" do
      {ext, _} = ext_with_store()

      assert Map.has_key?(ext.commands, "session-name")
    end

    test "'session-name' has the expected description" do
      {ext, _} = ext_with_store()

      assert ext.commands["session-name"].description =~ "session name"
    end

    test "registers no tools" do
      {ext, _} = ext_with_store()

      assert ext.tools == %{}
    end

    test "registers no event handlers" do
      {ext, _} = ext_with_store()

      assert ext.handlers == %{}
    end
  end

  describe "session-name handler — set" do
    test "sets the session name when args are provided" do
      {ext, agent} = ext_with_store()

      ext.commands["session-name"].handler.("My Project", nil)

      assert Agent.get(agent, & &1) == "My Project"
    end

    test "returns confirmation text after setting" do
      {ext, _} = ext_with_store()

      result = ext.commands["session-name"].handler.("My Project", nil)

      assert result == "Session named: My Project"
    end

    test "trims whitespace from the provided name" do
      {ext, agent} = ext_with_store()

      ext.commands["session-name"].handler.("  trimmed  ", nil)

      assert Agent.get(agent, & &1) == "trimmed"
    end
  end

  describe "session-name handler — get" do
    test "returns 'No session name set' when no name has been set" do
      {ext, _} = ext_with_store()

      result = ext.commands["session-name"].handler.("", nil)

      assert result == "No session name set"
    end

    test "returns the current session name after it has been set" do
      {ext, _} = ext_with_store()

      ext.commands["session-name"].handler.("My Session", nil)
      result = ext.commands["session-name"].handler.("", nil)

      assert result == "Session: My Session"
    end

    test "whitespace-only args are treated as a get request" do
      {ext, _} = ext_with_store()

      result = ext.commands["session-name"].handler.("   ", nil)

      assert result == "No session name set"
    end
  end
end
