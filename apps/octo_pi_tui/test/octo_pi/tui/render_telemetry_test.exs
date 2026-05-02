defmodule OctoPi.TUI.RenderTelemetryTest do
  @moduledoc """
  Telemetry contract tests for opi-4dx.1: render-path observability.

  Tests the helper module `OctoPi.TUI.RenderTelemetry` and verifies that
  call sites in AssistantMessage / Interactive emit the expected events.
  """

  use ExUnit.Case, async: false

  alias OctoPi.TUI.Components.AssistantMessage.TextBlock
  alias OctoPi.TUI.RenderContext
  alias OctoPi.TUI.RenderTelemetry
  alias OctoPi.TUI.Theme

  @theme Theme.load_builtin(:dark, :truecolor)

  def __telem_handler__(event, measurements, metadata, %{pid: pid}) do
    send(pid, {:telemetry, event, measurements, metadata})
  end

  setup do
    handler_id = "render-telem-#{System.unique_integer([:positive])}"

    events = [
      [:octo_pi_tui, :markdown, :render, :start],
      [:octo_pi_tui, :markdown, :render, :stop],
      [:octo_pi_tui, :interactive, :handle_info, :start],
      [:octo_pi_tui, :interactive, :handle_info, :stop],
      [:octo_pi_tui, :interactive, :mailbox],
      [:octo_pi_tui, :key, :latency]
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

  describe "RenderTelemetry.with_handle_info/2" do
    alias OctoPi.TUI.Key

    test "fires handle_info span + mailbox sample for hid_event" do
      mono_us = System.monotonic_time(:microsecond)

      result =
        RenderTelemetry.with_handle_info({:hid_event, %Key{key: ?h}, mono_us}, fn ->
          :handled
        end)

      assert result == :handled

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :start], _, %{kind: :hid_event}}

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :mailbox], %{message_queue_len: q},
                       %{at: :handle_info_entry}}

      assert is_integer(q) and q >= 0

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :stop], %{duration: _},
                       %{kind: :hid_event}}
    end

    test "emits key.latency for 3-tuple hid_event" do
      mono_us = System.monotonic_time(:microsecond) - 1_000

      RenderTelemetry.with_handle_info({:hid_event, %Key{key: ?j}, mono_us}, fn -> :ok end)

      assert_received {:telemetry, [:octo_pi_tui, :key, :latency], %{duration_us: dur}, meta}

      assert is_integer(dur)
      assert dur >= 1_000
      assert is_integer(meta.mailbox_len_at_arrival)
    end

    test "no key.latency for 2-tuple hid_event (legacy)" do
      RenderTelemetry.with_handle_info({:hid_event, %Key{key: ?k}}, fn -> :ok end)

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :start], _, %{kind: :hid_event}}

      refute_received {:telemetry, [:octo_pi_tui, :key, :latency], _, _}
    end

    test "kind metadata for :octo_pi_agent_event" do
      RenderTelemetry.with_handle_info({:octo_pi_agent_event, :anything}, fn -> :ok end)

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :start], _, %{kind: :octo_pi_agent_event}}
    end

    test "kind metadata for :timeout" do
      RenderTelemetry.with_handle_info(:timeout, fn -> :ok end)

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :start], _, %{kind: :timeout}}
    end

    test "kind metadata for :other catch-all" do
      RenderTelemetry.with_handle_info({:something_unexpected, "x"}, fn -> :ok end)

      assert_received {:telemetry, [:octo_pi_tui, :interactive, :handle_info, :start], _, %{kind: :other}}
    end
  end
end
