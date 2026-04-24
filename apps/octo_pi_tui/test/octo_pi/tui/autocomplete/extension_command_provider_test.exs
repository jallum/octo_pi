defmodule OctoPi.TUI.Autocomplete.ExtensionCommandProviderTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.{ExtensionCommandProvider, Suggestion}

  defp test_commands do
    [
      {"deploy", %{description: "Deploy to staging"}, "ext-deploy"},
      {"lint", %{description: "Run linter"}, "ext-lint"},
      {"test", %{description: "Run tests"}, "ext-test"}
    ]
  end

  describe "new/2" do
    test "creates provider filtering out builtin conflicts" do
      builtin_names = MapSet.new(["help", "clear", "test"])
      provider = ExtensionCommandProvider.new(test_commands(), builtin_names)
      assert length(provider.commands) == 2
    end

    test "empty builtins keeps all commands" do
      provider = ExtensionCommandProvider.new(test_commands(), MapSet.new())
      assert length(provider.commands) == 3
    end

    test "reports conflicts" do
      builtin_names = MapSet.new(["test"])
      provider = ExtensionCommandProvider.new(test_commands(), builtin_names)
      assert [{"test", "ext-test"}] = provider.conflicts
    end
  end

  describe "get_suggestions/2" do
    test "suggests matching commands on / prefix" do
      provider = ExtensionCommandProvider.new(test_commands(), MapSet.new())
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/de")
      assert [%Suggestion{label: "/deploy"}] = suggestions
    end

    test "returns all extension commands on /" do
      provider = ExtensionCommandProvider.new(test_commands(), MapSet.new())
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/")
      assert length(suggestions) == 3
    end

    test "no suggestions for non-slash input" do
      provider = ExtensionCommandProvider.new(test_commands(), MapSet.new())
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "deploy")
      assert suggestions == []
    end

    test "includes description in suggestions" do
      provider = ExtensionCommandProvider.new(test_commands(), MapSet.new())
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/lint")
      assert [%Suggestion{description: "Run linter"}] = suggestions
    end

    test "filters out conflicting commands" do
      builtin_names = MapSet.new(["test"])
      provider = ExtensionCommandProvider.new(test_commands(), builtin_names)
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/test")
      assert suggestions == []
    end
  end
end
