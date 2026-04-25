defmodule OctoPi.TUI.Components.AutocompleteDropdownTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Autocomplete
  alias OctoPi.TUI.Autocomplete.SlashCommandProvider
  alias OctoPi.TUI.Components.Input
  alias OctoPi.TUI.Key

  defp key(name), do: %Key{key: name}
  defp ctrl(char), do: %Key{key: char, modifiers: [:ctrl]}

  defp press(input, key_spec) do
    case Input.handle_key(input, key_spec) do
      {new_input, _events} -> new_input
      new_input -> new_input
    end
  end

  defp type(input, string) do
    string |> String.graphemes() |> Enum.reduce(input, &Input.insert(&2, &1))
  end

  defp test_provider do
    commands = [
      %Autocomplete.SlashCommand{name: "help", description: "Show help"},
      %Autocomplete.SlashCommand{name: "clear", description: "Clear screen"},
      %Autocomplete.SlashCommand{name: "compact", description: "Compact context"},
      %Autocomplete.SlashCommand{name: "model", description: "Switch model"}
    ]

    SlashCommandProvider.new(commands)
  end

  # ── Triggering ─────────────────────────────────────────────────

  describe "autocomplete triggering" do
    test "typing / triggers suggestions when provider is set" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      assert input.autocomplete_active
      assert length(input.autocomplete_suggestions) == 4
    end

    test "no trigger without provider" do
      input = type(%Input{}, "/")
      refute input.autocomplete_active
    end

    test "suggestions filter as user types" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/c")
      assert input.autocomplete_active
      labels = Enum.map(input.autocomplete_suggestions, & &1.label)
      assert "/clear" in labels
      assert "/compact" in labels
      refute "/help" in labels
    end

    test "autocomplete deactivates when prefix no longer matches" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/zzz")
      refute input.autocomplete_active
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "autocomplete navigation" do
    test "Down selects next item" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      assert input.autocomplete_selected == 0
      input = press(input, key(:down))
      assert input.autocomplete_selected == 1
    end

    test "Up selects previous item" do
      input =
        %Input{autocomplete_provider: test_provider()}
        |> type("/")
        |> press(key(:down))
        |> press(key(:up))

      assert input.autocomplete_selected == 0
    end

    test "Up wraps around" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      input = press(input, key(:up))
      assert input.autocomplete_selected == 3
    end
  end

  # ── Acceptance ─────────────────────────────────────────────────

  describe "autocomplete acceptance" do
    test "Tab accepts selected suggestion" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      input = press(input, key(:tab))
      refute input.autocomplete_active
      assert String.starts_with?(input.value, "/")
      assert String.length(input.value) > 1
    end

    test "Enter accepts selected suggestion when active" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      input = press(input, key(:enter))
      refute input.autocomplete_active
      assert String.starts_with?(input.value, "/")
    end
  end

  # ── Dismissal ──────────────────────────────────────────────────

  describe "autocomplete dismissal" do
    test "Escape dismisses dropdown" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      assert input.autocomplete_active
      input = press(input, key(:escape))
      refute input.autocomplete_active
    end

    test "Ctrl+C dismisses autocomplete (tui.select.cancel default binding)" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      assert input.autocomplete_active
      result = Input.handle_key(input, ctrl(?c))
      refute result.autocomplete_active
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render_dropdown/2" do
    test "returns empty when not active" do
      input = %Input{value: "hello"}
      assert Input.render_dropdown(input, 40) == []
    end

    test "returns suggestion lines when active" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      lines = Input.render_dropdown(input, 40)
      assert lines != []
    end

    test "highlights selected item with arrow prefix" do
      input = type(%Input{autocomplete_provider: test_provider()}, "/")
      lines = Input.render_dropdown(input, 40)
      assert Enum.any?(lines, &String.starts_with?(&1, "→ "))
    end
  end
end
