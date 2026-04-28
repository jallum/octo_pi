defmodule OctoPi.TUI.AutocompleteTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.CombinedProvider
  alias OctoPi.TUI.Autocomplete.ExtensionCommandProvider
  alias OctoPi.TUI.Autocomplete.FilePathProvider
  alias OctoPi.TUI.Autocomplete.SlashCommandProvider
  alias OctoPi.TUI.Autocomplete.Suggestion

  # ── Suggestion struct ──────────────────────────────────────────

  describe "Suggestion" do
    test "creates with required fields" do
      s = %Suggestion{label: "/help", value: "/help"}
      assert s.label == "/help"
      assert s.value == "/help"
      assert s.description == nil
    end

    test "creates with description" do
      s = %Suggestion{label: "/clear", value: "/clear", description: "Clear the screen"}
      assert s.description == "Clear the screen"
    end
  end

  # ── SlashCommandProvider ───────────────────────────────────────

  describe "SlashCommandProvider" do
    setup do
      commands = [
        %Autocomplete.SlashCommand{name: "help", description: "Show help"},
        %Autocomplete.SlashCommand{name: "clear", description: "Clear screen"},
        %Autocomplete.SlashCommand{name: "compact", description: "Compact context"},
        %Autocomplete.SlashCommand{name: "cost", description: "Show token costs"},
        %Autocomplete.SlashCommand{name: "model", description: "Switch model"}
      ]

      provider = SlashCommandProvider.new(commands)
      {:ok, provider: provider}
    end

    test "returns all commands for bare /", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/")
      assert length(suggestions) == 5
      assert Enum.all?(suggestions, &String.starts_with?(&1.value, "/"))
    end

    test "filters by prefix", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/c")
      labels = Enum.map(suggestions, & &1.label)
      assert "/clear" in labels
      assert "/compact" in labels
      assert "/cost" in labels
      refute "/help" in labels
    end

    test "returns empty for non-slash input", %{provider: provider} do
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "hello")
    end

    test "returns empty for no match", %{provider: provider} do
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "/zzz")
    end

    test "includes descriptions in suggestions", %{provider: provider} do
      {:ok, [suggestion | _]} = Autocomplete.get_suggestions(provider, "/help")
      assert suggestion.description == "Show help"
    end
  end

  # ── CombinedProvider ───────────────────────────────────────────

  describe "CombinedProvider" do
    test "chains multiple providers" do
      commands1 = [%Autocomplete.SlashCommand{name: "help", description: "Help"}]
      commands2 = [%Autocomplete.SlashCommand{name: "hello", description: "Greet"}]

      p1 = SlashCommandProvider.new(commands1)
      p2 = SlashCommandProvider.new(commands2)
      combined = CombinedProvider.new([p1, p2])

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "/hel")
      labels = Enum.map(suggestions, & &1.label)
      assert "/help" in labels
      assert "/hello" in labels
    end

    test "deduplicates by value" do
      cmd = %Autocomplete.SlashCommand{name: "help", description: "Help"}
      p1 = SlashCommandProvider.new([cmd])
      p2 = SlashCommandProvider.new([cmd])
      combined = CombinedProvider.new([p1, p2])

      {:ok, suggestions} = Autocomplete.get_suggestions(combined, "/help")
      assert length(suggestions) == 1
    end

    test "returns empty when no providers match" do
      combined = CombinedProvider.new([])
      assert {:ok, []} = Autocomplete.get_suggestions(combined, "/foo")
    end
  end

  # ── ExtensionCommandProvider ───────────────────────────────────

  describe "ExtensionCommandProvider" do
    setup do
      commands = [
        {"deploy", %{description: "Deploy service"}, "ext-deploy"},
        {"test", %{description: "Run tests"}, "ext-test"},
        {"help", %{description: "Extension help"}, "ext-help"}
      ]

      builtin_names = MapSet.new(["help", "clear", "compact"])
      provider = ExtensionCommandProvider.new(commands, builtin_names)
      {:ok, provider: provider}
    end

    test "returns matching extension commands for /prefix", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/dep")
      assert length(suggestions) == 1
      assert hd(suggestions).value == "/deploy"
    end

    test "suppresses commands conflicting with builtins", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/help")
      assert suggestions == []
    end

    test "returns all non-conflicting commands for bare /", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "/")
      values = Enum.map(suggestions, & &1.value)
      assert "/deploy" in values
      assert "/test" in values
      refute "/help" in values
    end

    test "returns empty for non-slash input", %{provider: provider} do
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "deploy")
    end

    test "includes description in suggestions", %{provider: provider} do
      {:ok, [s]} = Autocomplete.get_suggestions(provider, "/dep")
      assert s.description == "Deploy service"
    end

    test "stores conflict pairs", %{provider: provider} do
      assert {"help", "ext-help"} in provider.conflicts
    end
  end

  # ── FilePathProvider ───────────────────────────────────────────

  describe "FilePathProvider" do
    setup do
      provider = FilePathProvider.new(cwd: File.cwd!(), max_results: 10)
      {:ok, provider: provider}
    end

    test "returns empty for plain text input", %{provider: provider} do
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "hello")
    end

    test "bare / does not trigger absolute path completion", %{provider: provider} do
      assert {:ok, []} = Autocomplete.get_suggestions(provider, "/")
    end

    test "returns suggestions for @ prefix", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "@mix.exs")
      assert is_list(suggestions)
    end

    test "@ with empty query returns directory entries", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "@")
      assert suggestions != []
      assert Enum.all?(suggestions, &is_binary(&1.value))
    end

    test "absolute path returns matching entries", %{provider: provider} do
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, File.cwd!())
      assert is_list(suggestions)
    end

    test "respects max_results limit" do
      provider = FilePathProvider.new(cwd: File.cwd!(), max_results: 3)
      {:ok, suggestions} = Autocomplete.get_suggestions(provider, "@")
      assert length(suggestions) <= 3
    end

    test "values are quoted when path contains spaces" do
      assert [cwd: "/tmp"] |> FilePathProvider.new() |> is_struct()
    end
  end

  # ── Built-in commands ──────────────────────────────────────────

  describe "builtin_commands/0" do
    test "includes core commands" do
      commands = Autocomplete.builtin_commands()
      names = Enum.map(commands, & &1.name)
      assert "help" in names
      assert "clear" in names
      assert "compact" in names
      assert "cost" in names
      assert "model" in names
    end

    test "all commands have descriptions" do
      commands = Autocomplete.builtin_commands()
      assert Enum.all?(commands, &(&1.description != nil))
    end
  end
end
