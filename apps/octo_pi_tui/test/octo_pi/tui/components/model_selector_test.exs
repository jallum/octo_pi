defmodule OctoPi.TUI.Components.ModelSelectorTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.ModelSelector
  alias OctoPi.TUI.Key
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  defp strip_ansi(text) do
    String.replace(text, ~r/\e\][^\a]*\a|\e\[[0-9;]*m/, "")
  end

  defp key(name), do: %Key{key: name}

  defp press(selector, key_spec) do
    case ModelSelector.handle_key(selector, key_spec) do
      {new_selector, _events} -> new_selector
      new_selector -> new_selector
    end
  end

  defp test_models do
    [
      %{id: "claude-opus-4-6", name: "Opus", provider: :anthropic, context_window: 200_000},
      %{id: "claude-sonnet-4-6", name: "Sonnet", provider: :anthropic, context_window: 200_000},
      %{id: "gpt-4o", name: "GPT-4o", provider: :openai, context_window: 128_000}
    ]
  end

  # ── Construction ────────────────────────────────────────────────

  describe "new/3" do
    test "creates selector with models" do
      selector = ModelSelector.new(test_models(), @theme)
      assert selector.selected == 0
      assert length(selector.models) == 3
    end

    test "highlights current model if provided" do
      selector = ModelSelector.new(test_models(), @theme, current: "claude-sonnet-4-6")
      assert selector.current_id == "claude-sonnet-4-6"
    end
  end

  # ── Navigation ─────────────────────────────────────────────────

  describe "navigation" do
    test "Down moves selection" do
      selector = ModelSelector.new(test_models(), @theme) |> press(key(:down))
      assert selector.selected == 1
    end

    test "Up wraps to last item" do
      selector = ModelSelector.new(test_models(), @theme) |> press(key(:up))
      assert selector.selected == 2
    end

    test "Down wraps to first item" do
      selector =
        ModelSelector.new(test_models(), @theme)
        |> press(key(:down))
        |> press(key(:down))
        |> press(key(:down))

      assert selector.selected == 0
    end
  end

  # ── Selection ──────────────────────────────────────────────────

  describe "selection" do
    test "Enter emits select event with model" do
      selector = ModelSelector.new(test_models(), @theme)
      {_selector, events} = ModelSelector.handle_key(selector, key(:enter))
      assert [{:select_model, model}] = events
      assert model.id == "claude-opus-4-6"
    end

    test "Escape emits cancel" do
      selector = ModelSelector.new(test_models(), @theme)
      {_selector, events} = ModelSelector.handle_key(selector, key(:escape))
      assert [:cancel] = events
    end
  end

  # ── Rendering ──────────────────────────────────────────────────

  describe "render/2" do
    test "shows model IDs" do
      selector = ModelSelector.new(test_models(), @theme)
      lines = selector |> ModelSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "claude-opus-4-6"))
      assert Enum.any?(lines, &(&1 =~ "gpt-4o"))
    end

    test "marks current model" do
      selector = ModelSelector.new(test_models(), @theme, current: "gpt-4o")
      lines = selector |> ModelSelector.render(60) |> Enum.map(&strip_ansi/1)
      gpt_line = Enum.find(lines, &(&1 =~ "gpt-4o"))
      assert gpt_line =~ "✓"
    end

    test "highlights selected item" do
      selector = ModelSelector.new(test_models(), @theme)
      lines = ModelSelector.render(selector, 60)
      assert Enum.any?(lines, &(&1 =~ "\e[7m"))
    end

    test "shows provider name" do
      selector = ModelSelector.new(test_models(), @theme)
      lines = selector |> ModelSelector.render(60) |> Enum.map(&strip_ansi/1)
      assert Enum.any?(lines, &(&1 =~ "anthropic"))
    end
  end

  # ── Filter ─────────────────────────────────────────────────────

  describe "filtering" do
    test "typing filters models" do
      selector = ModelSelector.new(test_models(), @theme)
      selector = ModelSelector.filter(selector, "opus")
      assert length(selector.filtered_models) == 1
    end

    test "empty filter shows all" do
      selector = ModelSelector.new(test_models(), @theme)
      selector = ModelSelector.filter(selector, "")
      assert length(selector.filtered_models) == 3
    end
  end
end
