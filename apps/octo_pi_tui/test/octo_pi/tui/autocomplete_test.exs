defmodule OctoPi.TUI.AutocompleteTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.{CombinedProvider, SlashCommandProvider, Suggestion}

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
