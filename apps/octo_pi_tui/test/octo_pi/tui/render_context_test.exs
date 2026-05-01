defmodule OctoPi.TUI.RenderContextTest do
  use ExUnit.Case, async: true

  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  test "requires theme and width" do
    assert_raise ArgumentError, fn -> struct!(RenderContext, []) end
    assert_raise ArgumentError, fn -> struct!(RenderContext, theme: @theme) end
    assert_raise ArgumentError, fn -> struct!(RenderContext, width: 80) end
  end

  test "supplies defaults for padding_x, hide_thinking, hidden_thinking_label" do
    ctx = %RenderContext{theme: @theme, width: 80}
    assert ctx.padding_x == 1
    assert ctx.hide_thinking == false
    assert ctx.hidden_thinking_label == "Thinking..."
  end

  test "fields can be overridden" do
    ctx = %RenderContext{
      theme: @theme,
      width: 60,
      padding_x: 2,
      hide_thinking: true,
      hidden_thinking_label: "(hidden)"
    }

    assert ctx.padding_x == 2
    assert ctx.hide_thinking == true
    assert ctx.hidden_thinking_label == "(hidden)"
  end
end
