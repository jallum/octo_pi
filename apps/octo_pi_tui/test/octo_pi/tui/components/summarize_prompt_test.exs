defmodule OctoPi.TUI.Components.SummarizePromptTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.Components.SummarizePrompt
  alias OctoPi.TUI.Key

  defp press(state, atom) when is_atom(atom) do
    SummarizePrompt.handle_key(state, %Key{key: atom})
  end

  defp navigate_to(state, option) do
    target_idx = Enum.find_index(SummarizePrompt.options(), &(&1 == option))
    Enum.reduce(1..target_idx//1, state, fn _, s ->
      {s1, _} = press(s, :down)
      s1
    end)
  end

  # ── construction ──────────────────────────────────────────────────────────

  describe "new/1" do
    test "starts with first option selected" do
      s = SummarizePrompt.new()
      assert s.selected == 0
    end

    test "default title" do
      s = SummarizePrompt.new()
      assert s.title =~ "Summarize"
    end

    test "custom title override" do
      s = SummarizePrompt.new(title: "My prompt")
      assert s.title == "My prompt"
    end
  end

  # ── render/2 ─────────────────────────────────────────────────────────────

  describe "render/2" do
    test "shows all three options" do
      s = SummarizePrompt.new()
      lines = SummarizePrompt.render(s, 80)
      joined = Enum.join(lines, "\n")
      assert joined =~ "No summary"
      assert joined =~ "Summarize"
      assert joined =~ "Summarize with custom prompt"
    end

    test "shows title" do
      s = SummarizePrompt.new()
      lines = SummarizePrompt.render(s, 80)
      assert Enum.any?(lines, &(&1 =~ "Summarize branch?"))
    end

    test "cursor marks selected option" do
      s = SummarizePrompt.new()
      lines = SummarizePrompt.render(s, 80)
      assert Enum.any?(lines, &String.starts_with?(&1, "> No summary"))
      refute Enum.any?(lines, &String.starts_with?(&1, "> Summarize with custom prompt"))
    end
  end

  # ── navigation ────────────────────────────────────────────────────────────

  describe "navigation" do
    test "down moves selection forward" do
      s = SummarizePrompt.new()
      {s1, []} = press(s, :down)
      assert s1.selected == 1
    end

    test "up moves selection backward" do
      s = %SummarizePrompt{selected: 1}
      {s1, []} = press(s, :up)
      assert s1.selected == 0
    end

    test "down wraps at last option" do
      s = %SummarizePrompt{selected: 2}
      {s1, []} = press(s, :down)
      assert s1.selected == 0
    end

    test "up wraps at first option" do
      s = SummarizePrompt.new()
      {s1, []} = press(s, :up)
      assert s1.selected == 2
    end

    test "unrecognized key returns empty events" do
      s = SummarizePrompt.new()
      {s1, events} = press(s, :tab)
      assert s1 == s
      assert events == []
    end
  end

  # ── cancellation ─────────────────────────────────────────────────────────

  describe "cancellation" do
    test "escape emits :cancel" do
      s = SummarizePrompt.new()
      {_s1, events} = press(s, :escape)
      assert events == [:cancel]
    end
  end

  # ── selection — no summary ────────────────────────────────────────────────

  describe "select 'No summary'" do
    test "enter on first option emits {:result, :no}" do
      s = SummarizePrompt.new()
      assert s.selected == 0
      {_s1, events} = press(s, :enter)
      assert events == [{:result, :no}]
    end

    test "maps to user_wants_summary: :no" do
      s = SummarizePrompt.new()
      {_s1, [{:result, result}]} = press(s, :enter)
      assert result == :no
    end
  end

  # ── selection — summarize ─────────────────────────────────────────────────

  describe "select 'Summarize'" do
    test "enter on 'Summarize' emits {:result, :yes}" do
      s = SummarizePrompt.new() |> navigate_to("Summarize")
      {_s1, events} = press(s, :enter)
      assert events == [{:result, :yes}]
    end

    test "maps to user_wants_summary: :yes" do
      s = SummarizePrompt.new() |> navigate_to("Summarize")
      {_s1, [{:result, result}]} = press(s, :enter)
      assert result == :yes
    end
  end

  # ── selection — summarize with custom prompt ──────────────────────────────

  describe "select 'Summarize with custom prompt'" do
    test "enter emits :awaiting_custom_instructions" do
      s = SummarizePrompt.new() |> navigate_to("Summarize with custom prompt")
      {_s1, events} = press(s, :enter)
      assert events == [:awaiting_custom_instructions]
    end

    test "complete_custom/2 emits {:result, {:yes, text}}" do
      s = SummarizePrompt.new()
      {_s1, events} = SummarizePrompt.complete_custom(s, "focus on auth decisions")
      assert events == [{:result, {:yes, "focus on auth decisions"}}]
    end

    test "complete_custom/2 maps to user_wants_summary: {:yes, instructions}" do
      s = SummarizePrompt.new()
      {_s1, [{:result, result}]} = SummarizePrompt.complete_custom(s, "my instructions")
      assert result == {:yes, "my instructions"}
    end

    test "full flow: navigate → enter → editor → complete" do
      s = SummarizePrompt.new()

      # Navigate to custom option
      s = navigate_to(s, "Summarize with custom prompt")
      {s, [:awaiting_custom_instructions]} = press(s, :enter)

      # Caller would show editor; editor returns text; complete_custom maps it
      {_s, [{:result, result}]} = SummarizePrompt.complete_custom(s, "custom text")
      assert result == {:yes, "custom text"}
    end
  end

  # ── round-trip mapping to user_wants_summary ─────────────────────────────

  describe "mapping to user_wants_summary" do
    test "all three paths produce valid user_wants_summary values" do
      s = SummarizePrompt.new()

      # No summary
      {_s, [{:result, r_no}]} = press(s, :enter)
      assert r_no == :no

      # Summarize
      s_sum = navigate_to(s, "Summarize")
      {_s, [{:result, r_yes}]} = press(s_sum, :enter)
      assert r_yes == :yes

      # Custom
      s_custom = navigate_to(s, "Summarize with custom prompt")
      {s_w, [:awaiting_custom_instructions]} = press(s_custom, :enter)
      {_s, [{:result, r_custom}]} = SummarizePrompt.complete_custom(s_w, "instructions")
      assert r_custom == {:yes, "instructions"}
    end
  end
end
