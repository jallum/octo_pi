defmodule OctoPi.TUI.RenderTelemetryTest do
  @moduledoc """
  Telemetry contract tests for render-path observability.

  Verifies that call sites in AssistantMessage emit the expected markdown render events.
  """

  use ExUnit.Case, async: false

  alias OctoPi.TUI.Components.AssistantMessage.TextBlock
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  def __telem_handler__(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  setup do
    handler_id = "render-telem-#{System.unique_integer([:positive])}"

    events = [
      [:octo_pi_tui, :markdown, :render, :start],
      [:octo_pi_tui, :markdown, :render, :stop]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.__telem_handler__/4,
      %{pid: self()}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "markdown.render span (via TextBlock.render/2)" do
    test "fires start/stop with width, line_count, text_bytes" do
      block = %TextBlock{snapshot: "# Hello\n\nWorld."}
      ctx = %RenderContext{theme: @theme, width: 80}

      {_block, lines} = TextBlock.render(block, ctx)
      assert %OctoPi.TUI.VDOM.VLines{} = lines

      assert_received {:telemetry, [:octo_pi_tui, :markdown, :render, :start], _, start_meta}
      assert start_meta.width == 80

      assert_received {:telemetry, [:octo_pi_tui, :markdown, :render, :stop], stop_meas, stop_meta}
      assert is_integer(stop_meas.duration)
      assert stop_meas.duration >= 0
      assert stop_meta.text_bytes == byte_size("# Hello\n\nWorld.")
      assert stop_meta.line_count > 0
    end

    test "fires for empty snapshot too (line_count is 0)" do
      block = %TextBlock{snapshot: ""}
      ctx = %RenderContext{theme: @theme, width: 40}

      TextBlock.render(block, ctx)

      assert_received {:telemetry, [:octo_pi_tui, :markdown, :render, :start], _, _}
      assert_received {:telemetry, [:octo_pi_tui, :markdown, :render, :stop], _, stop_meta}
      assert stop_meta.text_bytes == 0
    end
  end
end
