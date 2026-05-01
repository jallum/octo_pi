defmodule OctoPi.TUI.CompatTest.BadLegacy do
  defstruct [:value]
  def render(_, _), do: :not_a_list
end

defmodule OctoPi.TUI.CompatTest.LegacyText do
  @moduledoc false
  defstruct [:text]

  alias OctoPi.TUI.RenderContext

  # Old contract: render(state, width) :: [binary()]
  def render(%__MODULE__{text: text}, width) when is_integer(width) do
    [String.pad_trailing(text, width)]
  end

  # Transcript contract: render(state, ctx) :: {state, lines, frame_ms}
  def render(%__MODULE__{text: text} = state, %RenderContext{width: width}) do
    {state, [String.pad_trailing(text, width)], nil}
  end
end

defmodule OctoPi.TUI.CompatTest do
  use ExUnit.Case, async: true
  alias OctoPi.TUI.{Compat, VDOM, RenderContext}
  alias OctoPi.TUI.CompatTest.LegacyText
  alias OctoPi.TUI.CompatTest.BadLegacy

  describe "wrap_old_contract" do
    test "wraps legacy component as VLines" do
      state = %LegacyText{text: "hello"}
      result = Compat.wrap_old_contract(LegacyText, state, 20)

      assert %VDOM.VLines{lines: [line]} = result
      assert String.trim_trailing(line) =~ "hello"
    end

    test "rejects invalid return type" do
      assert_raise ArgumentError, fn ->
        Compat.wrap_old_contract(BadLegacy, %BadLegacy{}, 80)
      end
    end

    test "computes visible width correctly" do
      state = %LegacyText{text: "test"}
      vlines = Compat.wrap_old_contract(LegacyText, state, 10)
      width = Compat.visible_width_of_vlines(vlines)
      assert width == 10
    end

    test "empty lines" do
      defmodule EmptyLegacy do
        def render(_, _), do: []
      end

      result = Compat.wrap_old_contract(EmptyLegacy, %{}, 80)
      assert %VDOM.VLines{lines: []} = result
    end
  end

  describe "wrap_transcript_contract" do
    test "wraps transcript component returning VLines and state" do
      state = %LegacyText{text: "world"}
      ctx = %RenderContext{theme: nil, width: 15}
      {vlines, new_state} = Compat.wrap_transcript_contract(LegacyText, state, ctx)

      assert %VDOM.VLines{} = vlines
      assert new_state == state

      [line] = vlines.lines
      assert String.trim_trailing(line) =~ "world"
    end

    test "rejects invalid return type" do
      defmodule BadTranscript do
        def render(_, _), do: {:bad, :shape}
      end

      assert_raise ArgumentError, fn ->
        Compat.wrap_transcript_contract(BadTranscript, %{}, %RenderContext{
          theme: nil,
          width: 80
        })
      end
    end
  end

  describe "enabled?" do
    test "returns boolean from application env" do
      # Should be false by default
      assert is_boolean(Compat.enabled?())
    end
  end

  describe "visible_width_of_vlines" do
    test "empty lines" do
      assert Compat.visible_width_of_vlines(%VDOM.VLines{lines: []}) == 0
    end

    test "with ANSI codes" do
      vlines = %VDOM.VLines{lines: ["\e[31mred\e[0m"]}
      width = Compat.visible_width_of_vlines(vlines)
      assert width == 3
    end
  end
end