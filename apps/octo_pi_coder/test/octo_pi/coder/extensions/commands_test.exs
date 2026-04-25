defmodule OctoPi.Coder.Extensions.CommandsTest do
  use ExUnit.Case, async: true

  alias OctoPi.Coder.Extension.API
  alias OctoPi.Coder.Extension.Loader
  alias OctoPi.Coder.Extensions.Commands

  defp ext_with_commands(available_commands) do
    factory = fn api ->
      api = API.bind_core(api, %{get_commands: fn -> available_commands end})
      Commands.init(api)
    end

    {:ok, ext} = Loader.load_from_factory("commands", factory)
    ext
  end

  describe "init/1" do
    test "registers a command named 'commands'" do
      ext = ext_with_commands([])

      assert Map.has_key?(ext.commands, "commands")
    end

    test "'commands' has the expected description" do
      ext = ext_with_commands([])

      assert ext.commands["commands"].description == "List available slash commands"
    end

    test "registers no tools" do
      ext = ext_with_commands([])

      assert ext.tools == %{}
    end

    test "registers no event handlers" do
      ext = ext_with_commands([])

      assert ext.handlers == %{}
    end
  end

  describe "commands handler" do
    test "empty filter returns all commands" do
      all = [
        %{name: "foo", source: "extension"},
        %{name: "bar", source: "prompt"}
      ]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("", nil)

      assert result == all
    end

    test "whitespace-only filter returns all commands" do
      all = [%{name: "foo", source: "extension"}]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("   ", nil)

      assert result == all
    end

    test "source filter returns only matching commands" do
      all = [
        %{name: "foo", source: "extension"},
        %{name: "bar", source: "prompt"},
        %{name: "baz", source: "extension"}
      ]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("extension", nil)

      assert length(result) == 2
      assert Enum.all?(result, &(&1.source == "extension"))
    end

    test "filter matching no commands returns empty list" do
      all = [%{name: "foo", source: "extension"}]

      ext = ext_with_commands(all)
      result = ext.commands["commands"].handler.("skill", nil)

      assert result == []
    end

    test "no available commands returns empty list" do
      ext = ext_with_commands([])
      result = ext.commands["commands"].handler.("", nil)

      assert result == []
    end
  end
end
